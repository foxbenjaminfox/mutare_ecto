defmodule Mutare.Ecto.Fragment do
  @moduledoc """
  The plugin's **own** SQL-semantics mutation catalog for a query fragment — the boolean
  condition of a `where`/`having` clause or of a free-standing `dynamic/1,2`. Given a condition's
  AST, `mutants/1` returns every *single-point* variant: the same condition with **exactly one**
  operator/predicate swapped, one variant per mutatable position. Each variant is a full,
  compile-safe alternative the SQL engine will actually run; the host (`Mutare.Ecto.Host`) weaves
  them behind a `^`/`dynamic` selector so one of them bakes into the query per run, while
  `Mutare.Ecto.Dynamic` rebuilds a free-standing `dynamic` call whole (an ordinary expression
  position, needing no weave).

  The catalog reuses **none** of Mutare's built-in mutators: the operators look like Elixir's
  but they evaluate under SQL's semantics — three-valued boolean logic for the connectives,
  NULL handling for the predicates, boundary behaviour for the comparisons — so a borrowed
  Elixir-semantics mutator would silently drop genuinely killable mutants. The families:

    * **Comparison** — `>`↔`>=`, `<`↔`<=`, `==`↔`!=`. Boundary and equality coverage. The
      `==`/`!=` swap is a real, killable change — in SQL both forms exclude `NULL` rows (the
      comparison is unknown) and differ on every concrete value, so it is never "equivalent".
    * **Connective** — `and`↔`or`. Genuinely three-valued (a `NULL` operand is neither true nor
      false); its equivalences differ from Elixir's, so it is owned here, never reused from core.
    * **NullPredicate** — `is_nil(x)`↔`not is_nil(x)`. The uniquely-SQL family with no Elixir
      analog worth borrowing; treated as one unit so `not is_nil(x)` flips back to `is_nil(x)`
      rather than producing a double-negation.
    * **Membership** — `x in ^list`↔`x not in ^list` (polarity, a unit like NullPredicate) and
      `like`↔`ilike` (case-sensitivity; an atom-form swap). `ilike` is Postgres-specific, so the
      `like`↔`ilike` swap is **dialect-gated** — emitted only when `dialects:` includes `:postgres`
      (the `x in ^list` polarity is portable and always emitted).
    * **Arithmetic** — `+`↔`-`, `*`↔`/`. Owned here for SQL's numeric semantics: NULL propagates
      through every arm alike (the swap changes a row's computed value, never its NULL-ness), and
      `/` is the *database's* division — integer truncation and a zero divisor raising are the
      engine's behaviour, not Elixir's float `//2`. Binary forms only: the `-` of a written
      negative number (`-5`) is arity-1 sign syntax, not an operator to swap.
    * **IntegerLiteral** — a *non-pinned* integer literal written into the fragment
      (`u.age > 18` → `19`/`17`/`0`): boundary (`n±1`) plus the zero sentinel, deduped and never
      equal to the original.
    * **FloatLiteral** — a *non-pinned* float literal (`u.score > 2.5` → `3.5`/`1.5`/`0.0`):
      boundary (`n±1.0`) plus the `0.0` sentinel, the same shape as the integer arm.
    * **StringLiteral** — a plain string literal (`u.name == "ok"` → `""`/`"mutare"`): the empty
      string and the `"mutare"` sentinel, dropping whichever already equals the original.
    * **BooleanLiteral** — `true`↔`false` (core's `Literal` boolean arm). A direct boolean
      *comparison* is rarely idiomatic, but a boolean in a non-comparison position (a flag deeper
      in a fragment) is worth flipping — it is worth mutating exactly when it is worth using.
    * **AtomLiteral** — any *other* literal atom (`u.status == :active` → `:mutare`): the
      `:mutare` sentinel, dropped when the atom already is the sentinel. `true`/`false` are
      BooleanLiteral's; `nil` is excluded (it is NULL/absence, with no clean swap).

  These literal arms are owned here — not borrowed from core's `Literal`/`FloatLiteral`/
  `StringLiteral`/`AtomLiteral` — for the same reason the operator families are: the literal is
  part of the SQL the query runs, not interpolated Elixir, so core never sees it (the clause is
  raw/`:hosted`). They follow core's value conventions but are decided here under SQL semantics.
  Each is named after the *type* it mutates (`integer_literal`, …), never after `fragment(...)`,
  with which it has nothing to do.

  Pinned interpolations (`^min_age`) and field references (`u.age`) are left untouched: a `^value`
  is ordinary Elixir bound upstream and mutated there by core's literal families — the catalog
  targets the SQL-evaluated *operators and structure*, plus the in-fragment literals core can't reach.

  A literal arm is also suppressed at a **structural position** of a known Ecto DSL form, where the
  literal shapes the SQL the builder emits rather than carrying data (mutating it yields a broken
  query, not a live mutant): the `fragment` template (arg 0), the interval unit of
  `datetime_add`/`date_add` (arg 2) and `from_now`/`ago` (arg 1), and the cast type of `type/2`
  (arg 1). The traversal threads each child's `{parent_form, arity, index}` down so the literal
  arms can consult this small registry (`structural_position?/1`); data literals at every *other*
  position of those forms are still mutated.

  A nested **author macro** the catalog walks past (a query helper the app defines and uses inside
  the fragment) may define its own argument grammar — Mutare sees source, not the expansion, and a
  macro is free to accept arguments that are valid Elixir *tokens* but not standard Elixir/Ecto
  syntax. So the catalog descends into a nested call's argument **only** when it is plainly a standard
  expression: either the node is not a known macro at all, or the macro routed that argument
  `:expression` (read from the resolve-pass stamp via `Mutare.Transform.Calls.macro_treatment/1`).
  Any other routing — `:skip`, `:pattern`, `:hosted`, … — marks an argument whose meaning is the
  macro's own, so it is left raw. We mutate only what the author wrote in a form we understand.
  """

  alias Mutare.Ecto.{AST, Config}
  alias Mutare.Transform.Calls

  # The finer `# mutare:ignore` label(s) a mutant carries beyond its family — the operator a swap
  # mutates (`<`), or a literal's kind (`zero`) — or a *list* when one mutant collapses several kinds
  # (a deduped `0` is both `pred` and `zero`). It lets `# mutare:ignore[ecto:<]` suppress just the
  # `<` swap while the `>` swap on the same line keeps running. Folded into the plugin's variant
  # vocabulary by `Mutare.Ecto.variants/0` (the labels here are the source of `variant_labels/0`).
  @type label :: String.t() | [String.t()]

  # Each operator's single SQL-meaningful swap, by family. `:count`-style arity-changing or
  # NULL-equivalent rewrites are deliberately absent. The `like`/`ilike`
  # case-sensitivity swap is dialect-gated (Postgres) in `local/4`.
  @comparison_swaps %{:> => :>=, :>= => :>, :< => :<=, :<= => :<, :== => :!=, :!= => :==}
  @connective_swaps %{:and => :or, :or => :and}
  @membership_op_swaps %{:like => :ilike, :ilike => :like}

  # Arithmetic pairs by identity structure: `+`↔`-` (identity 0) and `*`↔`/` (identity 1). Portable
  # across dialects (unlike `like`↔`ilike`), same arity both ways (always compiles), NULL-neutral
  # (SQL arithmetic propagates NULL through every arm identically). Applied to **binary** forms
  # only — see the arity guard in `local/4`.
  @arithmetic_swaps %{:+ => :-, :- => :+, :* => :/, :/ => :*}

  # The literal-arm sentinels, mirroring core's families (`Mutare.Mutators.AtomLiteral` /
  # `StringLiteral`): a literal atom collapses to `:mutare`, a string to the empty string or
  # `"mutare"`. Reused from core's `Mutare.AST` so the survivor marker matches the built-ins.
  @atom_sentinel Mutare.AST.sentinel_atom()
  @string_sentinel Mutare.AST.sentinel_string()

  @doc """
  Every single-point mutant of a `where`/`having` condition as `{family, node, label}` triples, or
  `[]` when the condition has nothing the catalog mutates (a bare boolean column, a keyword-shorthand
  value, an interpolation). One triple per mutatable position, each the full condition with that one
  position swapped, tagged with the SQL `family` that produced it (so the caller can filter by
  `families:`) **and** the finer `label` naming the operator/kind it swapped (so a qualified
  `# mutare:ignore[ecto:<]` can suppress just that one). `opts` carries `dialects:` — the
  `like`↔`ilike` swap is emitted only under `:postgres`.
  """
  @spec mutants(Macro.t(), keyword() | Config.t()) :: [{Config.family(), Macro.t(), label()}]
  def mutants(condition, opts \\ []), do: do_mutants(condition, opts, nil)

  @doc false
  # The finer variant labels every fragment family can emit — the operators the swap families mutate
  # (derived from the swap tables, so the vocabulary can't drift from what's produced) plus the unit
  # and value kinds. `Mutare.Ecto.variants/0` folds these in alongside the family names.
  @spec variant_labels() :: [String.t()]
  def variant_labels do
    swap_ops =
      [@comparison_swaps, @connective_swaps, @membership_op_swaps, @arithmetic_swaps]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&to_string/1)

    swap_ops ++ ~w(in is_nil succ pred zero empty sentinel negate)
  end

  # NullPredicate, as a unit. `not is_nil(x)` → `is_nil(x)`: flip the whole predicate, never
  # descend into the inner `is_nil` (that would also offer `is_nil` → `not is_nil`, yielding a
  # redundant `not not is_nil(x)`).
  # Both directions are tagged `"is_nil"` (`not is_nil` has a space — not a wire-safe label), so
  # `# mutare:ignore[ecto:is_nil]` suppresses the null-predicate flip whichever way it points.
  defp do_mutants({:not, _meta, [{:is_nil, _, [_arg]} = inner]}, _opts, _position),
    do: [{:null_predicate, inner, "is_nil"}]

  # `is_nil(x)` → `not is_nil(x)`. A unit too: its argument is a column reference with no
  # catalog operators, so there is nothing to descend into. Clean meta on the fresh `not`.
  defp do_mutants({:is_nil, _meta, [_arg]} = node, _opts, _position),
    do: [{:null_predicate, {:not, [], [node]}, "is_nil"}]

  # Membership polarity, as a unit (mirrors NullPredicate). `x not in ^list` → `x in ^list`:
  # flip the whole predicate, no descent (its operands — a field and a pinned list — carry no
  # catalog target; the list's *value* is core's). Portable, always emitted. Both directions are
  # tagged `"in"` (`not in` has a space), so `# mutare:ignore[ecto:in]` names the polarity flip.
  defp do_mutants({:not, _meta, [{:in, _, [_l, _r]} = inner]}, _opts, _position),
    do: [{:membership, inner, "in"}]

  # `x in ^list` → `x not in ^list`. A unit too. Clean meta on the fresh `not`.
  defp do_mutants({:in, _meta, [_l, _r]} = node, _opts, _position),
    do: [{:membership, {:not, [], [node]}, "in"}]

  # A literal (int/float/string/bool/atom) written directly into the fragment (Sourceror-wrapped).
  # At a *structural* position of a known Ecto DSL form — the `fragment` template, an interval unit
  # of `datetime_add`/`date_add`/`from_now`/`ago`, or the cast type of `type/2` — the literal is
  # part of the SQL the builder emits, not data: mutating it yields a broken query, never a live
  # mutant, so it is skipped (`structural_position?/1` consults the registry, off the
  # `{parent_form, arity, index}` threaded down from `lift/4`). Elsewhere each type emits its own
  # SQL-safe, labelled mutants via `literal_mutants/1`. A *pinned* `^value` is not this shape and
  # never reaches here.
  defp do_mutants({:__block__, _meta, [lit]} = node, _opts, position)
       when is_integer(lit) or is_float(lit) or is_binary(lit) or is_atom(lit) do
    if structural_position?(position), do: [], else: literal_mutants(node)
  end

  # An operator/connective (atom form): offer its own swap (if any), then descend into its
  # operands so a nested comparison/connective is mutated too (`is_nil(u.x) and u.y > 1`).
  defp do_mutants({form, meta, args}, opts, _position) when is_atom(form) and is_list(args) do
    # mutare:ignore[operand_swap] local/lift order is irrelevant — mutants are consumed as a set
    local(form, meta, args, opts) ++ lift(form, meta, args, opts)
  end

  # A non-atom-form node (e.g. a `u.age` field access, whose form is the `{:., …}` dot tuple):
  # descend into its arguments only, never its form — exactly as core's analyzer recurses, so a
  # field/qualifier reference is a leaf.
  # mutare:ignore[pattern_swap, clause_drop] equivalent — the only non-atom-form node a condition yields is a field/dot access whose args are `[]`, and lift/4 over no args is a no-op, so reordering the head's bindings or dropping the clause both produce the same empty result
  defp do_mutants({form, meta, args}, opts, _position) when is_list(args),
    do: lift(form, meta, args, opts)

  # Variables, 2-tuples, lists, bare atoms: no catalog target (interpolations are core's; the
  # `in`/`like` membership forms are handled by their own clauses above).
  defp do_mutants(_node, _opts, _position), do: []

  # IntegerLiteral: an integer literal written into the fragment (Sourceror-wrapped). Boundary
  # (`n±1`) plus the zero sentinel, deduped and never equal to `n` — owned here so it stays
  # SQL-safe (core can't reach it: the clause is raw).
  defp literal_mutants({:__block__, _meta, [int]}) when is_integer(int) do
    value_mutants(
      [{int + 1, "succ"}, {int - 1, "pred"}, {0, "zero"}],
      int,
      :integer_literal,
      &AST.int_literal/1
    )
  end

  # FloatLiteral: mirrors the integer arm with a `1.0` step and a `0.0` sentinel (core's
  # `FloatLiteral` convention), deduped and never equal to `f`.
  defp literal_mutants({:__block__, _meta, [f]}) when is_float(f) do
    value_mutants(
      [{f + 1.0, "succ"}, {f - 1.0, "pred"}, {0.0, "zero"}],
      f,
      :float_literal,
      &AST.float_literal/1
    )
  end

  # StringLiteral: a plain string literal → the empty string (`empty`) and the `"mutare"` sentinel
  # (core's `StringLiteral` convention), dropping whichever already equals the original — so a
  # typical string yields two mutants. An interpolated string is a `<<>>` node, not this `:__block__`
  # shape, so it is left to core upstream.
  defp literal_mutants({:__block__, _meta, [s]}) when is_binary(s) do
    value_mutants(
      [{"", "empty"}, {@string_sentinel, "sentinel"}],
      s,
      :string_literal,
      &AST.string_literal/1
    )
  end

  # BooleanLiteral: `true` ↔ `false` (core's `Literal` boolean arm). Not aimed at direct boolean
  # comparisons (rarely idiomatic), but at a boolean used elsewhere in a fragment — worth mutating
  # exactly when it is worth using. `nil` is *not* a boolean and is left alone (NULL/absence).
  defp literal_mutants({:__block__, _meta, [bool]}) when is_boolean(bool),
    do: [{:boolean_literal, AST.atom_literal(not bool), "negate"}]

  # AtomLiteral: any other literal atom → the `:mutare` sentinel (core's `AtomLiteral` convention),
  # dropped when the atom already is the sentinel. `true`/`false` are BooleanLiteral's (above) and
  # `nil` is excluded — it is NULL/absence, with no clean swap.
  defp literal_mutants({:__block__, _meta, [atom]})
       when is_atom(atom) and atom not in [true, false, nil] and atom != @atom_sentinel,
       do: [{:atom_literal, AST.atom_literal(@atom_sentinel), "sentinel"}]

  # `nil` and the already-sentinel atom carry no clean swap.
  defp literal_mutants(_node), do: []

  # A *small registry* of known Ecto DSL forms and the argument positions whose literal is
  # *structural* — part of the SQL the query builder emits, not data — keyed off the
  # `{parent_form, arity, index}` threaded down from `lift/4`. The top-level condition has no
  # parent (`nil`) and is never structural.
  #
  #   * `fragment(template, …)`        — arg 0 is the SQL template (any arity)
  #   * `datetime_add(_, _, interval)` — arg 2 is the interval unit
  #   * `date_add(_, _, interval)`     — arg 2 is the interval unit
  #   * `from_now(_, interval)`        — arg 1 is the interval unit
  #   * `ago(_, interval)`             — arg 1 is the interval unit
  #   * `type(_, type)`                — arg 1 is the cast type
  defp structural_position?({:fragment, _arity, 0}), do: true
  defp structural_position?({:datetime_add, 3, 2}), do: true
  defp structural_position?({:date_add, 3, 2}), do: true
  defp structural_position?({:from_now, 2, 1}), do: true
  defp structural_position?({:ago, 2, 1}), do: true
  defp structural_position?({:type, 2, 1}), do: true
  defp structural_position?(_position), do: false

  # The atom-form node's own single swap, tagged by family **and** by the operator it swaps (the
  # source `form`, e.g. `<`) — so `# mutare:ignore[ecto:<]` names just this swap. `like`↔`ilike` is
  # dialect-gated (Postgres); comparison/connective are portable.
  defp local(form, meta, args, opts) do
    cond do
      Map.has_key?(@comparison_swaps, form) ->
        [{:comparison, {@comparison_swaps[form], meta, args}, to_string(form)}]

      Map.has_key?(@connective_swaps, form) ->
        [{:connective, {@connective_swaps[form], meta, args}, to_string(form)}]

      Map.has_key?(@membership_op_swaps, form) and Config.dialect_enabled?(opts, [:postgres]) ->
        [{:membership, {@membership_op_swaps[form], meta, args}, to_string(form)}]

      # Binary only: a written negative number (`-5`) parses as the arity-1 `-` over the wrapped
      # literal — sign syntax, not an operator (and Ecto has no unary `+` to swap it to). Its inner
      # literal is still reached by `lift/4` as usual.
      Map.has_key?(@arithmetic_swaps, form) and length(args) == 2 ->
        [{:arithmetic, {@arithmetic_swaps[form], meta, args}, to_string(form)}]

      true ->
        []
    end
  end

  # Rebuild `{form, meta, args}` once per single mutation of one of its arguments — so each
  # produced node differs from the original in exactly one descendant position, carrying the
  # family **and** the finer label the descendant mutation was tagged with. Each child is descended
  # with its `{parent_form, arity, index}` position so `do_mutants/3` can skip a literal at a
  # structural position of a known Ecto DSL form.
  #
  # A nested macro the **author** wrote in the fragment (a query helper of their own) may not accept
  # standard Ecto syntax in its arguments — it can define its own DSL out of valid tokens, so we
  # cannot assume an argument parses to anything we know how to mutate. Core left the whole hosted
  # fragment raw and stamped each recognised nested call's per-argument routing on the node, so read
  # it with `Calls.macro_treatment/1` and descend into an argument **only** when it is plainly a
  # standard expression — `descend_arg?/2` below.
  defp lift(form, meta, args, opts) do
    arity = length(args)
    routing = Calls.macro_treatment({form, meta, args})

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      if descend_arg?(routing, index) do
        for {family, mutated, label} <- do_mutants(arg, opts, {form, arity, index}),
            do: {family, {form, meta, List.replace_at(args, index, mutated)}, label}
      else
        []
      end
    end)
  end

  # Descend into an argument only when its syntax is the standard DSL we know how to mutate: either
  # the node is not a known macro (`nil` routing — an ordinary operator/call/field we own) or the
  # macro routed this argument `:expression` (the one treatment that asserts "a standard expression
  # here, mutate it"). Every other treatment — `:skip`, `:pattern`, `:binding_pattern`, `:hosted`,
  # `:pinned`, `{:keyword, …}` — marks an argument whose grammar is the macro's own, so it is left
  # raw. We mutate only what the author wrote in a form we understand.
  defp descend_arg?(nil, _index), do: true
  defp descend_arg?(routing, index), do: Enum.at(routing, index) == :expression

  # Build `{family, literal_node, labels}` for each distinct mutated value: drop any candidate equal
  # to the original, then dedup by value while **merging** the kind labels of colliding candidates —
  # so `1`'s `pred` (`n-1` = 0) and its `zero` sentinel collapse to one `0` tagged `["pred", "zero"]`
  # (mirroring core's `Literal`), and a qualifier naming *either* suppresses it. Order-stable.
  defp value_mutants(candidates, original, family, build) do
    candidates
    |> Enum.reject(fn {value, _kind} -> value == original end)
    |> Enum.reduce([], fn {value, kind}, acc ->
      case List.keyfind(acc, value, 0) do
        nil -> acc ++ [{value, [kind]}]
        {^value, kinds} -> List.keyreplace(acc, value, 0, {value, kinds ++ [kind]})
      end
    end)
    |> Enum.map(fn {value, kinds} -> {family, build.(value), kinds} end)
  end
end
