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
  killable mutants. The Milestone-2 families:

    * **Comparison** — `>`↔`>=`, `<`↔`<=`, `==`↔`!=`. Boundary and equality coverage. The
      `==`/`!=` swap interacts with `NULL` (it changes which `NULL` rows are excluded) — a
      real, killable change under three-valued logic, never suppressed as "equivalent".
    * **Connective** — `and`↔`or`. Three-valued; its equivalences differ from Elixir's, so it
      is owned here, never reused from core.
    * **NullPredicate** — `is_nil(x)`↔`not is_nil(x)`. The uniquely-SQL family with no Elixir
      analog worth borrowing; treated as one unit so `not is_nil(x)` flips back to `is_nil(x)`
      rather than producing a double-negation.

  Pinned interpolations (`^min_age`), field references (`u.age`), and literals are left
  untouched: a `^value` is ordinary Elixir bound upstream and mutated there by core's literal
  families — the catalog targets only the SQL-evaluated *operators and structure* (see
  `DESIGN.md`, "Pinned values are core's").
  """

  # Comparison + Connective: each operator's single SQL-meaningful swap. `:count`-style
  # arity-changing or NULL-equivalent rewrites are deliberately absent (see DESIGN.md).
  @op_swaps %{
    :> => :>=,
    :>= => :>,
    :< => :<=,
    :<= => :<,
    :== => :!=,
    :!= => :==,
    :and => :or,
    :or => :and
  }

  @doc """
  Every single-point mutant of a `where`/`having` condition, or `[]` when the condition has
  nothing the catalog mutates (a bare boolean column, a keyword-shorthand value, an
  interpolation). One mutant per mutatable position, each the full condition with that one
  position swapped.
  """
  @spec mutants(Macro.t()) :: [Macro.t()]
  def mutants(condition), do: do_mutants(condition)

  # NullPredicate, as a unit. `not is_nil(x)` → `is_nil(x)`: flip the whole predicate, never
  # descend into the inner `is_nil` (that would also offer `is_nil` → `not is_nil`, yielding a
  # redundant `not not is_nil(x)`).
  defp do_mutants({:not, _meta, [{:is_nil, _, [_arg]} = inner]}), do: [inner]

  # `is_nil(x)` → `not is_nil(x)`. A unit too: its argument is a column reference with no
  # catalog operators, so there is nothing to descend into. Clean meta on the fresh `not`.
  defp do_mutants({:is_nil, _meta, [_arg]} = node), do: [{:not, [], [node]}]

  # An operator/connective (atom form): offer its own swap (if any), then descend into its
  # operands so a nested comparison/connective is mutated too (`is_nil(u.x) and u.y > 1`).
  defp do_mutants({form, meta, args}) when is_atom(form) and is_list(args) do
    local =
      case Map.get(@op_swaps, form) do
        nil -> []
        to -> [{to, meta, args}]
      end

    local ++ lift(form, meta, args)
  end

  # A non-atom-form node (e.g. a `u.age` field access, whose form is the `{:., …}` dot tuple):
  # descend into its arguments only, never its form — exactly as core's analyzer recurses, so a
  # field/qualifier reference is a leaf.
  defp do_mutants({form, meta, args}) when is_list(args), do: lift(form, meta, args)

  # Literals, atoms, variables, 2-tuples, lists: no catalog target (interpolations and literals
  # are core's; lists/`in` membership are Milestone 3).
  defp do_mutants(_node), do: []

  # Rebuild `{form, meta, args}` once per single mutation of one of its arguments — so each
  # produced node differs from the original in exactly one descendant position.
  defp lift(form, meta, args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      for mutated <- do_mutants(arg), do: {form, meta, List.replace_at(args, index, mutated)}
    end)
  end
end
