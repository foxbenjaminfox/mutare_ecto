defmodule Mutare.Ecto.Fragment do
  @moduledoc """
  The plugin's **own** SQL-semantics mutation catalog for a query fragment — the boolean
  condition of a `where`/`having` clause. Given a condition's AST, `mutants/1` returns every
  *single-point* variant: the same condition with **exactly one** operator/predicate swapped,
  one variant per mutatable position. Each variant is a full, compile-safe alternative the SQL
  engine will actually run; the host (`Mutare.Ecto.Host`) weaves them behind a `^`/`dynamic`
  selector so one of them bakes into the query per run.

  The catalog reuses **none** of Mutare's built-in mutators (see `DESIGN.md`, "The semantic
  boundary"): the operators look like Elixir's but the equivalence reasoning is SQL's
  three-valued logic, so a borrowed Elixir-semantics mutator would silently drop genuinely
  killable mutants. The families:

    * **Comparison** — `>`↔`>=`, `<`↔`<=`, `==`↔`!=`. Boundary and equality coverage. The
      `==`/`!=` swap interacts with `NULL` (it changes which `NULL` rows are excluded) — a
      real, killable change under three-valued logic, never suppressed as "equivalent".
    * **Connective** — `and`↔`or`. Three-valued; its equivalences differ from Elixir's, so it
      is owned here, never reused from core.
    * **NullPredicate** — `is_nil(x)`↔`not is_nil(x)`. The uniquely-SQL family with no Elixir
      analog worth borrowing; treated as one unit so `not is_nil(x)` flips back to `is_nil(x)`
      rather than producing a double-negation.
    * **Membership** — `x in ^list`↔`x not in ^list` (polarity, a unit like NullPredicate) and
      `like`↔`ilike` (case-sensitivity; an atom-form swap). `ilike` is Postgres-specific, so the
      `like`↔`ilike` swap is **dialect-gated** — emitted only when `dialects:` includes `:postgres`
      (the `x in ^list` polarity is portable and always emitted).
    * **FragmentLiteral** — a *non-pinned* integer literal written into the fragment
      (`u.age > 18` → `19`/`17`/`0`). The library owns these so it can keep them SQL-safe:
      they are part of the SQL the query runs, not interpolated Elixir, so core never sees
      them (the clause is raw/`:hosted`). Boundary (`n±1`) plus the zero sentinel, deduped
      and never equal to the original — the same boundary convention as core's `Literal`, but
      decided here under SQL semantics.

  Pinned interpolations (`^min_age`), field references (`u.age`), and *string* literals are
  left untouched: a `^value` is ordinary Elixir bound upstream and mutated there by core's
  literal families — the catalog targets only the SQL-evaluated *operators and structure* (see
  `DESIGN.md`, "Pinned values are core's"), plus the in-fragment integer literals core can't
  reach.
  """

  alias Mutare.Ecto.{AST, Config}

  @type family :: atom()

  # Each operator's single SQL-meaningful swap, by family. `:count`-style arity-changing or
  # NULL-equivalent rewrites are deliberately absent (see DESIGN.md). The `like`/`ilike`
  # case-sensitivity swap is dialect-gated (Postgres) in `local/4`.
  @comparison_swaps %{:> => :>=, :>= => :>, :< => :<=, :<= => :<, :== => :!=, :!= => :==}
  @connective_swaps %{:and => :or, :or => :and}
  @membership_op_swaps %{:like => :ilike, :ilike => :like}

  @doc """
  Every single-point mutant of a `where`/`having` condition as `{family, node}` pairs, or `[]`
  when the condition has nothing the catalog mutates (a bare boolean column, a keyword-shorthand
  value, an interpolation). One pair per mutatable position, each the full condition with that one
  position swapped, tagged with the SQL family that produced it (so the caller can filter by
  `families:`). `opts` carries `dialects:` — the `like`↔`ilike` swap is emitted only under
  `:postgres`.
  """
  @spec mutants(Macro.t(), keyword()) :: [{family(), Macro.t()}]
  def mutants(condition, opts \\ []), do: do_mutants(condition, opts)

  @doc """
  Binding-reorder mutants: for each pair of `binding_names` that **both** appear in `condition`,
  the condition with those two binding references swapped throughout (`a.x == b.y` → `b.x == a.y`).

  Reordering a query's declared binding list `[a, b]` → `[b, a]` is equivalent to swapping the
  body's references while keeping the declared order (`DESIGN.md`, "Binding reorder is the same
  mechanism") — and since the host re-declares each `dynamic`'s own binding list, the plugin just
  emits the swapped *body* and rides the host. Requiring both bindings to appear keeps the mutant
  a genuine reference swap (and avoids reaching for a column on the wrong schema). The host calls
  this with the binding list it already extracted; for a single-binding query it returns `[]`.
  """
  @spec binding_reorders(Macro.t(), [atom()]) :: [Macro.t()]
  def binding_reorders(condition, binding_names) when is_list(binding_names) do
    present = Enum.filter(binding_names, &AST.references_var?(condition, &1))

    for {a, i} <- Enum.with_index(present),
        {b, j} <- Enum.with_index(present),
        i < j,
        do: swap_vars(condition, a, b)
  end

  # Swap every variable node named `a` with `b` and vice versa (a transposition of the two
  # bindings). Only variable nodes (`{name, meta, ctx}` with an atom `ctx`) are touched, so a
  # pinned value or field name that happens to share a name is unaffected.
  defp swap_vars(ast, a, b) do
    Macro.prewalk(ast, fn
      {^a, meta, ctx} when is_atom(ctx) -> {b, meta, ctx}
      {^b, meta, ctx} when is_atom(ctx) -> {a, meta, ctx}
      other -> other
    end)
  end

  # NullPredicate, as a unit. `not is_nil(x)` → `is_nil(x)`: flip the whole predicate, never
  # descend into the inner `is_nil` (that would also offer `is_nil` → `not is_nil`, yielding a
  # redundant `not not is_nil(x)`).
  defp do_mutants({:not, _meta, [{:is_nil, _, [_arg]} = inner]}, _opts),
    do: [{:null_predicate, inner}]

  # `is_nil(x)` → `not is_nil(x)`. A unit too: its argument is a column reference with no
  # catalog operators, so there is nothing to descend into. Clean meta on the fresh `not`.
  defp do_mutants({:is_nil, _meta, [_arg]} = node, _opts),
    do: [{:null_predicate, {:not, [], [node]}}]

  # Membership polarity, as a unit (mirrors NullPredicate). `x not in ^list` → `x in ^list`:
  # flip the whole predicate, no descent (its operands — a field and a pinned list — carry no
  # catalog target; the list's *value* is core's). Portable, always emitted.
  defp do_mutants({:not, _meta, [{:in, _, [_l, _r]} = inner]}, _opts), do: [{:membership, inner}]

  # `x in ^list` → `x not in ^list`. A unit too. Clean meta on the fresh `not`.
  defp do_mutants({:in, _meta, [_l, _r]} = node, _opts), do: [{:membership, {:not, [], [node]}}]

  # FragmentLiteral: an integer literal written into the fragment (Sourceror-wrapped). Boundary
  # (`n±1`) plus the zero sentinel, deduped and never equal to `n` — owned here so it stays
  # SQL-safe (core can't reach it: the clause is raw). String/atom literals are left alone
  # (their mutation is not SQL-meaningful here); a *pinned* `^value` never reaches this clause.
  defp do_mutants({:__block__, _meta, [int]}, _opts) when is_integer(int) do
    [int + 1, int - 1, 0]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == int))
    |> Enum.map(&{:fragment_literal, AST.int_literal(&1)})
  end

  # An operator/connective (atom form): offer its own swap (if any), then descend into its
  # operands so a nested comparison/connective is mutated too (`is_nil(u.x) and u.y > 1`).
  defp do_mutants({form, meta, args}, opts) when is_atom(form) and is_list(args) do
    # mutare:ignore[operand_swap] local/lift order is irrelevant — mutants are consumed as a set
    local(form, meta, args, opts) ++ lift(form, meta, args, opts)
  end

  # A non-atom-form node (e.g. a `u.age` field access, whose form is the `{:., …}` dot tuple):
  # descend into its arguments only, never its form — exactly as core's analyzer recurses, so a
  # field/qualifier reference is a leaf.
  defp do_mutants({form, meta, args}, opts) when is_list(args), do: lift(form, meta, args, opts)

  # Literals, atoms, variables, 2-tuples, lists: no catalog target (interpolations and literals
  # are core's; the `in`/`like` membership forms are handled by their own clauses above).
  defp do_mutants(_node, _opts), do: []

  # The atom-form node's own single swap, tagged by family. `like`↔`ilike` is dialect-gated
  # (Postgres); comparison/connective are portable.
  defp local(form, meta, args, opts) do
    cond do
      Map.has_key?(@comparison_swaps, form) ->
        [{:comparison, {@comparison_swaps[form], meta, args}}]

      Map.has_key?(@connective_swaps, form) ->
        [{:connective, {@connective_swaps[form], meta, args}}]

      Map.has_key?(@membership_op_swaps, form) and Config.dialect_enabled?(opts, [:postgres]) ->
        [{:membership, {@membership_op_swaps[form], meta, args}}]

      true ->
        []
    end
  end

  # Rebuild `{form, meta, args}` once per single mutation of one of its arguments — so each
  # produced node differs from the original in exactly one descendant position, carrying the
  # family the descendant mutation was tagged with.
  defp lift(form, meta, args, opts) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      for {family, mutated} <- do_mutants(arg, opts),
          do: {family, {form, meta, List.replace_at(args, index, mutated)}}
    end)
  end
end
