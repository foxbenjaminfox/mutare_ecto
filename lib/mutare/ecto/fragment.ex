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
      rather than producing a double-negation. Its argument is **never descended**: the value
      families (arithmetic, the literal arms) preserve an expression's NULL-ness — they change the
      value, never whether it is NULL — so their mutants are *provably equivalent* inside the one
      predicate that observes only NULL-ness, and the sole NULL-ness-changing mutation (the
      coalesce drop) would only apply under an `is_nil` the author already wrote constant
      (`is_nil(coalesce(x, d))` is false for every row when `d` is non-NULL). Emitting either
      would manufacture the always-equivalent noise the catalog exists to avoid.
    * **Membership** — `x in ^list`↔`x not in ^list` and `exists(subquery)`↔`not exists(subquery)`
      (polarity flips that treat the predicate as one unit — the reverse direction flips back, no
      double negation), plus one **element drop** per entry of a *written* in-list
      (`x in [1, 2, 3]` → `x in [2, 3]`/…, shrinking the membership set), and `like`↔`ilike`
      (case-sensitivity; an atom-form swap). `ilike` is Postgres-specific, so the `like`↔`ilike`
      swap is **dialect-gated** — emitted only when `dialects:` includes `:postgres` (the
      `in`/`exists` polarities and the element drop are portable and always emitted). Unlike
      `is_nil`, the `in` predicate's operands **are** descended — an arithmetic swap on the left
      or a literal inside the written list changes which rows match. An `exists`/`all`/`any`/`in`
      subquery argument is not descended *as a condition* (a subquery is a query, not this
      condition's syntax), but its **interior is recursed** by `Mutare.Ecto.Subquery` — the inner
      `where`/`having` swaps, filter-drops, and join-type flips (and, under a value-wrapper, its
      `select` projection) — each rebuilt into this condition and delivered through the same weave.
    * **Arithmetic** — `+`↔`-`, `*`↔`/`, owned by the shared scalar catalog (`Mutare.Ecto.Scalar`,
      which also delivers it in `select`/`order_by` values): NULL propagates through every arm
      alike (the swap changes a row's computed value, never its NULL-ness), and `/` is the
      *database's* division — integer truncation and a zero divisor raising are the engine's
      behaviour, not Elixir's float `//2`. Binary forms only: the `-` of a written negative
      number (`-5`) is arity-1 sign syntax, not an operator to swap.
    * **Coalesce** — `coalesce(x, default)` → `x`, dropping the NULL fallback (also
      `Mutare.Ecto.Scalar`, also delivered in `select`/`order_by` values). The one catalog
      mutation that *changes* an expression's NULL-ness — its entire point: the forms differ
      exactly on the rows where `x` is NULL, so a survivor carries the NULL-data note.
    * **Temporal** — `ago(n, unit)`↔`from_now(n, unit)`, the time-direction flip of Ecto's
      interval helpers. The pair is symmetric around *now* (same distance, opposite side), so a
      comparison against them differs only for rows inside that window — the family's
      equivalence note names exactly that. The interval `unit` stays structural (never mutated,
      as below); the count is ordinary data and keeps its literal mutants.
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

  Pinned interpolations (`^value`) and field references (`u.age`) are left untouched by the
  catalog: a pin's interior is ordinary Elixir evaluated at runtime and bound as a query
  parameter, so it is exactly **core's** business, never this catalog's — an SQL-rationale swap
  there (`^(min * 2)` → `^(min / 2)`) would reason about Elixir code in SQL's semantics, the
  mirror image of the mistake this catalog exists to avoid. The catalog targets the SQL-evaluated
  *operators and structure*, plus the in-fragment literals core can't reach; `islands/1` hands
  each pin interior to the condition's owner — the selector host for a hosted `where`/`having`,
  `Mutare.Ecto.Dynamic` for a free-standing `dynamic` — which sub-contracts it to core's own
  generation (`Mutare.Analyze.expression_mutations/3` — see `Mutare.Ecto.Host.Catalog`).

  A literal arm is also suppressed at a **structural position** of a known Ecto DSL form, where the
  literal shapes the SQL the builder emits rather than carrying data (mutating it yields a broken
  query, not a live mutant): the `fragment` template (arg 0), the interval unit of
  `datetime_add`/`date_add` (arg 2) and `from_now`/`ago` (arg 1), the cast type of `type/2`
  (arg 1), the column name of `field/2` (arg 1), the binding name of `as/1`/`parent_as/1`
  (arg 0), and the alias name of `selected_as/1,2` (its last argument). The traversal threads each
  child's `{parent_form, arity, index}` down so the literal
  arms can consult this small registry (`structural_position?/1`); data literals at every *other*
  position of those forms are still mutated.

  A nested **author macro** the catalog walks past (a query helper the app defines and uses inside
  the fragment) may define its own argument grammar — Mutare sees source, not the expansion, and a
  macro is free to accept arguments that are valid Elixir *tokens* but not standard Elixir/Ecto
  syntax. So the catalog descends into a nested call's argument **only** when it is plainly a standard
  expression: either the node is not a known macro at all, or the macro routed that argument
  `:expression` (read from the resolve-pass stamp via `Mutare.Calls.macro_treatment/1`).
  Any other routing — `:skip`, `:pattern`, `:hosted`, … — marks an argument whose meaning is the
  macro's own, so it is left raw. We mutate only what the author wrote in a form we understand.
  """

  alias Mutare.Calls
  alias Mutare.Ecto.{Config, Scalar, Subquery}

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

  # The interval helpers' time-direction flip. A same-arity rename (`ago/2`↔`from_now/2`), so the
  # mutant always compiles, and the structural-position registry stays aligned — both forms carry
  # their unit at arg 1. Portable: every adapter that runs the original runs the swap.
  @temporal_swaps %{ago: :from_now, from_now: :ago}

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

  @doc """
  Every interpolation **island** (`^expr`) in the condition, as `{interior, rebuild}` pairs —
  `interior` is the pin's Elixir expression and `rebuild.(mutated_interior)` is the full condition
  with exactly that pin's interior replaced (the pin itself kept). The condition's owner — the
  selector host for a hosted `where`/`having`, `Mutare.Ecto.Dynamic` for a free-standing
  `dynamic` — feeds each interior to core's generation (`Mutare.Analyze.expression_mutations/3`)
  and relays the rebuilds through its own delivery with `producer:` attribution
  (`Mutare.Ecto.Host.Catalog.subcontracted/3`), so a pin interior is mutated by the reasoner that
  owns Elixir — under the user's configured core families — while delivery stays the caller's
  (the host's weave, or the whole-call in-place rewrite).

  The walk honors exactly the catalog's own descent rules, so a caller cannot reach an island the
  catalog would not have walked past: an `is_nil` argument is never entered (value mutants of a
  parameter preserve its NULL-ness, so they are provably equivalent inside the one predicate that
  observes only NULL-ness); an `exists`/`all`/`any`/`in` subquery argument surfaces the pins inside
  the subquery's own mutated clauses (via `Mutare.Ecto.Subquery`, each rebuilt back into this
  condition) — its `where`/`having` conditions, plus a value-wrapper's observed `select` (never an
  EXISTS select, unobserved) — those interiors are ordinary Elixir, core's to mutate, exactly like a
  top-level pin; a nested author macro's argument is entered only when routed `:expression` (or not a
  macro at all); and the pin itself is a boundary — core owns everything beneath it, including any
  nested pin (`^` does not nest in Ecto).
  """
  @spec islands(Macro.t()) :: [{Macro.t(), (Macro.t() -> Macro.t())}]
  def islands(condition), do: island_walk(condition)

  defp island_walk({:^, meta, [interior]}), do: [{interior, &{:^, meta, [&1]}}]

  # `is_nil`'s argument is never entered: the value families preserve an expression's NULL-ness, so
  # a pin's value mutants are provably equivalent inside a predicate that observes only NULL-ness.
  defp island_walk({:is_nil, _meta, [_arg]}), do: []

  # `exists`'s argument is a subquery whose own condition pins **are** ordinary Elixir, core's to
  # mutate — so descend into its interior islands (via `Mutare.Ecto.Subquery`) and re-wrap each
  # rebuild inside the `exists`. (A bare inline `from` argument only; a `subquery(var)`/scalar
  # `from` yields nothing.)
  defp island_walk({:exists, ex_meta, [arg]}) do
    for {interior, rebuild} <- Subquery.interior_islands(arg, :existence),
        do: {interior, fn m -> {:exists, ex_meta, [rebuild.(m)]} end}
  end

  # Any other call/operator node: descend per argument under the same author-macro rule as
  # `lift/4` — only plainly standard syntax (`descend_arg?/2`). Each found island's rebuild is
  # composed outward so it reconstructs the whole condition. A bare inline subquery `from(...)`
  # (a value-wrapper's argument, reached by this descent) also surfaces its interior condition
  # pins through `Subquery`; every other node's `interior_islands` is `[]`.
  defp island_walk({form, meta, args} = node) when is_list(args) do
    routing = Calls.macro_treatment({form, meta, args})

    descended =
      args
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg, index} ->
        if descend_arg?(routing, index) do
          for {interior, rebuild} <- island_walk(arg) do
            {interior, fn m -> {form, meta, List.replace_at(args, index, rebuild.(m))} end}
          end
        else
          []
        end
      end)

    # mutare:ignore[operand_swap] equivalent — the per-argument islands and the subquery interior islands are independent, consumed as a set
    descended ++ Subquery.interior_islands(node, :value)
  end

  # A plain list (a written in-list): an island may sit among the elements (`x in [1, ^two]`).
  defp island_walk(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, index} ->
      for {interior, rebuild} <- island_walk(el) do
        {interior, fn m -> List.replace_at(list, index, rebuild.(m)) end}
      end
    end)
  end

  # Variables, field references, literals, 2-tuples: no pin can hide here.
  defp island_walk(_node), do: []

  @doc false
  # The finer variant labels every fragment-owned family can emit — the operators the swap families
  # mutate (derived from the swap tables, so the vocabulary can't drift from what's produced) plus
  # the unit and value kinds. `Mutare.Ecto.variants/0` folds these in alongside the family names
  # (the arithmetic operators arrive via `Mutare.Ecto.Scalar.variant_labels/0`, which owns them).
  @spec variant_labels() :: [String.t()]
  def variant_labels do
    swap_ops =
      [@comparison_swaps, @connective_swaps, @membership_op_swaps, @temporal_swaps]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&to_string/1)

    # mutare:ignore[operand_swap] equivalent — the result is consumed as a set of known labels, never order-sensitive
    swap_ops ++ ~w(in element exists is_nil succ pred zero empty sentinel negate)
  end

  # NullPredicate, as a unit. `not is_nil(x)` → `is_nil(x)`: flip the whole predicate, never
  # descend into the inner `is_nil` (that would also offer `is_nil` → `not is_nil`, yielding a
  # redundant `not not is_nil(x)`).
  # Both directions are tagged `"is_nil"` (`not is_nil` has a space — not a wire-safe label), so
  # `# mutare:ignore[ecto:is_nil]` suppresses the null-predicate flip whichever way it points.
  defp do_mutants({:not, _meta, [{:is_nil, _, [_arg]} = inner]}, _opts, _position),
    do: [{:null_predicate, inner, "is_nil"}]

  # `is_nil(x)` → `not is_nil(x)`. The argument is deliberately **not** descended — and not
  # because there is nothing there (`is_nil(u.a + u.b)` is legal SQL): the value families
  # preserve an expression's NULL-ness (an arithmetic/literal swap changes the value, never
  # whether it is NULL), so inside a predicate that asks *only* about NULL-ness their mutants are
  # provably equivalent — and the coalesce drop, the one NULL-ness-changing mutation, would only
  # fire under an `is_nil` the author already wrote constantly false. Clean meta on the fresh `not`.
  defp do_mutants({:is_nil, _meta, [_arg]} = node, _opts, _position),
    do: [{:null_predicate, {:not, [], [node]}, "is_nil"}]

  # Membership. `x not in list` → `x in list`: flip the whole predicate as a unit (no double
  # negation) — but unlike `is_nil`, the operands *are* worth descending: an arithmetic swap on
  # the left or a literal bump inside a written list changes which rows match. Descent mutants
  # (and the element drops of a written list) are rebuilt inside the `not`, so each stays a
  # single-point variant of the full predicate. Both polarity directions are tagged `"in"`
  # (`not in` has a space), so `# mutare:ignore[ecto:in]` names the polarity flip.
  defp do_mutants({:not, meta, [{:in, imeta, [_l, _r] = iargs} = inner]}, opts, _position) do
    [
      {:membership, inner, "in"}
      # mutare:ignore[operand_swap] equivalent — two independent mutant lists, consumed as a set
      | rewrap(element_drops(inner) ++ lift(:in, imeta, iargs, opts), meta)
    ]
  end

  # `x in list` → `x not in list` (clean meta on the fresh `not`), plus the element drops of a
  # written list and the operand descent — a pinned `^list` or a field reference yields nothing.
  defp do_mutants({:in, meta, [_l, _r] = args} = node, opts, _position) do
    [
      {:membership, {:not, [], [node]}, "in"}
      # mutare:ignore[operand_swap] equivalent — two independent mutant lists, consumed as a set
      | element_drops(node) ++ lift(:in, meta, args, opts)
    ]
  end

  # Existence polarity, as a unit (the subquery cousin of the `in` flip — SQL's other membership
  # predicate), **plus** the subquery's own interior mutants. `not exists(subquery)` →
  # `exists(subquery)` flips the whole predicate (`"exists"` — `not exists` has a space, not a
  # wire-safe label — so `# mutare:ignore[ecto:exists]` names the flip whichever way it points);
  # the interior mutants come from `Mutare.Ecto.Subquery` in `:existence` mode (its `select` is
  # unobserved by EXISTS, so it is suppressed there), each re-wrapped inside the `not exists`.
  defp do_mutants({:not, not_meta, [{:exists, ex_meta, [arg]} = inner]}, opts, _position) do
    interior =
      for {family, mutated, label} <- Subquery.interior_mutants(arg, opts, :existence),
          do: {family, {:not, not_meta, [{:exists, ex_meta, [mutated]}]}, label}

    # mutare:ignore[operand_swap] equivalent — the polarity flip and the interior set are independent, consumed as a set
    [{:membership, inner, "exists"} | interior]
  end

  # `exists(subquery)` → `not exists(subquery)` (clean meta on the fresh `not`), plus the subquery's
  # interior mutants in `:existence` mode, each re-wrapped inside the `exists`.
  defp do_mutants({:exists, ex_meta, [arg]} = node, opts, _position) do
    interior =
      for {family, mutated, label} <- Subquery.interior_mutants(arg, opts, :existence),
          do: {family, {:exists, ex_meta, [mutated]}, label}

    # mutare:ignore[operand_swap] equivalent — the polarity flip and the interior set are independent, consumed as a set
    [{:membership, {:not, [], [node]}, "exists"} | interior]
  end

  # An interpolation island (`^expr`): ordinary Elixir evaluated at runtime and bound as a query
  # parameter — never SQL for this catalog to reason about (a swap here changes the *parameter's*
  # Elixir value/type under an SQL rationale). The catalog contributes nothing and never descends;
  # `islands/1` collects the interior for the host's core sub-contract instead.
  defp do_mutants({:^, _meta, _args}, _opts, _position), do: []

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
    cond do
      structural_position?(position) -> []
      json_path_position?(position) -> json_path_mutants(node)
      true -> literal_mutants(node)
    end
  end

  # A Sourceror block wrapping a written list argument is transparent syntax: thread the incoming
  # position through, so the list's elements keep the parent *call's* position (a
  # `json_extract_path` path element must know it is one — see `json_path_position?/1`).
  # mutare:ignore[guard_drop] equivalent — the literal clause above already claims every non-list scalar Sourceror wraps in a single-element block (int/float/binary/atom), so by clause order only a genuine list ever reaches here regardless of this guard
  defp do_mutants({:__block__, meta, [list]}, opts, position) when is_list(list) do
    for {family, mutated, label} <- do_mutants(list, opts, position),
        do: {family, {:__block__, meta, [mutated]}, label}
  end

  # An operator/connective (atom form): offer its own swap (if any), then descend into its
  # operands so a nested comparison/connective is mutated too (`is_nil(u.x) and u.y > 1`). A bare
  # inline subquery `from(...)` (the argument of a value-wrapper — `all`/`any`/`subquery`/`in` —
  # reached here by the operand descent above) has no swap of its own, but `Subquery` recurses its
  # interior in `:value` mode; every other node's `interior_mutants` is `[]`.
  defp do_mutants({form, meta, args} = node, opts, _position)
       when is_atom(form) and is_list(args) do
    # mutare:ignore[operand_swap] local/lift/subquery order is irrelevant — mutants are consumed as a set
    local(form, meta, args, opts) ++
      lift(form, meta, args, opts) ++
      Subquery.interior_mutants(node, opts, :value)
  end

  # A non-atom-form node (e.g. a `u.age` field access, whose form is the `{:., …}` dot tuple, or a
  # qualified `Ecto.Query.from(...)` subquery): descend into its arguments only, never its form —
  # exactly as core's analyzer recurses — and offer a qualified subquery's interior in `:value` mode.
  # mutare:ignore[pattern_swap, clause_drop] equivalent — the only non-atom-form node a condition yields is a field/dot access whose args are `[]`, and lift/4 over no args is a no-op, so reordering the head's bindings or dropping the clause both produce the same empty result
  defp do_mutants({form, meta, args} = node, opts, _position) when is_list(args),
    # mutare:ignore[operand_swap] lift/subquery order is irrelevant — mutants are consumed as a set
    do: lift(form, meta, args, opts) ++ Subquery.interior_mutants(node, opts, :value)

  # A plain list — the written right-hand side of an `in`, or a `json_extract_path` path
  # (Sourceror wraps it as `{:__block__, …, [[…]]}`, whose block the transparent clause above
  # descends through): descend per element, so an in-list literal is fragment SQL exactly like a
  # bare one. Elements inherit the *list's* position — the registry is keyed by call-argument
  # positions, and a path element's constraints are the path argument's.
  defp do_mutants(list, opts, position) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, index} ->
      for {family, mutated, label} <- do_mutants(el, opts, position),
          do: {family, List.replace_at(list, index, mutated), label}
    end)
  end

  # Variables, 2-tuples, bare atoms: no catalog target (interpolations are core's; the
  # `in`/`like` membership forms are handled by their own clauses above).
  defp do_mutants(_node, _opts, _position), do: []

  # Membership set shrink: one mutant per element of a **written** in-list, each dropping that
  # single element (`x in [1, 2, 3]` → `x in [2, 3]` / `[1, 3]` / `[1, 2]`) — "does any test pin
  # this member?". Only a literal list the author wrote qualifies: a pinned `^list`, a field
  # reference, or a subquery right-hand side has no written elements to drop. A singleton drops
  # to `x in []` (constantly false — still valid, trivially killable SQL). Tagged `"element"`
  # so `# mutare:ignore[ecto:element]` names the drops apart from the polarity flip.
  defp element_drops({:in, meta, [l, {:__block__, lmeta, [elems]}]}) when is_list(elems) do
    for index <- 0..(length(elems) - 1)//1 do
      dropped = {:__block__, lmeta, [List.delete_at(elems, index)]}
      {:membership, {:in, meta, [l, dropped]}, "element"}
    end
  end

  defp element_drops(_node), do: []

  # Rebuild each descent/drop mutant of a reverse-polarity unit's inner predicate back inside the
  # written `not`, keeping the tag — so the emitted node is the full condition, single-point.
  defp rewrap(mutants, meta), do: for({f, m, l} <- mutants, do: {f, {:not, meta, [m]}, l})

  # IntegerLiteral: an integer literal written into the fragment (Sourceror-wrapped). Boundary
  # (`n±1`) plus the zero sentinel, deduped and never equal to `n` — owned here so it stays
  # SQL-safe (core can't reach it: the clause is raw).
  defp literal_mutants({:__block__, _meta, [int]}) when is_integer(int) do
    value_mutants([{int + 1, "succ"}, {int - 1, "pred"}, {0, "zero"}], int, :integer_literal)
  end

  # FloatLiteral: mirrors the integer arm with a `1.0` step and a `0.0` sentinel (core's
  # `FloatLiteral` convention), deduped and never equal to `f`.
  defp literal_mutants({:__block__, _meta, [f]}) when is_float(f) do
    value_mutants([{f + 1.0, "succ"}, {f - 1.0, "pred"}, {0.0, "zero"}], f, :float_literal)
  end

  # StringLiteral: a plain string literal → the empty string (`empty`) and the `"mutare"` sentinel
  # (core's `StringLiteral` convention), dropping whichever already equals the original — so a
  # typical string yields two mutants. An interpolated string is a `<<>>` node, not this `:__block__`
  # shape, so it is left to core upstream.
  defp literal_mutants({:__block__, _meta, [s]}) when is_binary(s) do
    value_mutants([{"", "empty"}, {@string_sentinel, "sentinel"}], s, :string_literal)
  end

  # BooleanLiteral: `true` ↔ `false` (core's `Literal` boolean arm). Not aimed at direct boolean
  # comparisons (rarely idiomatic), but at a boolean used elsewhere in a fragment — worth mutating
  # exactly when it is worth using. `nil` is *not* a boolean and is left alone (NULL/absence).
  defp literal_mutants({:__block__, _meta, [bool]}) when is_boolean(bool),
    do: [{:boolean_literal, Mutare.AST.literal(not bool), "negate"}]

  # AtomLiteral: any other literal atom → the `:mutare` sentinel (core's `AtomLiteral` convention),
  # dropped when the atom already is the sentinel. `true`/`false` are BooleanLiteral's (above) and
  # `nil` is excluded — it is NULL/absence, with no clean swap.
  defp literal_mutants({:__block__, _meta, [atom]})
       # mutare:ignore[literal] equivalent — the preceding is_boolean/1 clause already claims every true/false atom, so by clause order neither value can ever reach this guard regardless of which of the two is named here
       when is_atom(atom) and atom not in [true, false, nil] and atom != @atom_sentinel,
       do: [{:atom_literal, Mutare.AST.literal(@atom_sentinel), "sentinel"}]

  # `nil` and the already-sentinel atom carry no clean swap.
  defp literal_mutants(_node), do: []

  # A literal in a **JSON path position** — a bracket-access key (`p.meta["k"]`, `p.tags[0]`) or
  # a `json_extract_path` path element — selects which JSON element the SQL reads: ordinary data
  # (a different path differs exactly on rows carrying the original one), *except* that Ecto's
  # path validator accepts only literal strings and literal integers, and a negative integer
  # renders as unary minus (`-1` is `-(1)` in the AST) — rejected at expansion, which would
  # poison the whole metamutant build. So an integer index keeps only its non-negative mutants;
  # every other literal kind mutates as usual.
  defp json_path_mutants({:__block__, _meta, [int]}) when is_integer(int) do
    [{int + 1, "succ"}, {int - 1, "pred"}, {0, "zero"}]
    |> Enum.filter(fn {value, _kind} -> value >= 0 end)
    |> value_mutants(int, :integer_literal)
  end

  defp json_path_mutants(node), do: literal_mutants(node)

  # The JSON path positions: the key argument of a bracket access (the parser desugars `x[k]`
  # to a dot-call on the bare `Access` atom) and the path argument of `json_extract_path/2`
  # (whose written list's elements inherit the position — see the list clause).
  defp json_path_position?({{:., _, [Access, :get]}, 2, 1}), do: true
  defp json_path_position?({:json_extract_path, 2, 1}), do: true
  defp json_path_position?(_position), do: false

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
  #   * `field(_, name)`               — arg 1 is the column name (a mutated name is a wrong —
  #                                      usually nonexistent — column, not a live mutant)
  #   * `as(name)` / `parent_as(name)` — arg 0 names a query binding (a mutated name is an
  #                                      unknown-binding error at query build)
  #   * `selected_as(name)` /
  #     `selected_as(_, name)`         — the last arg names a select alias (a mutated name is an
  #                                      unknown-alias error at query build)
  defp structural_position?({:fragment, _arity, 0}), do: true
  defp structural_position?({:datetime_add, 3, 2}), do: true
  defp structural_position?({:date_add, 3, 2}), do: true
  defp structural_position?({:from_now, 2, 1}), do: true
  defp structural_position?({:ago, 2, 1}), do: true
  defp structural_position?({:type, 2, 1}), do: true
  defp structural_position?({:field, 2, 1}), do: true
  defp structural_position?({:as, 1, 0}), do: true
  defp structural_position?({:parent_as, 1, 0}), do: true
  defp structural_position?({:selected_as, 1, 0}), do: true
  defp structural_position?({:selected_as, 2, 1}), do: true
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

      # `ago(n, unit)` ↔ `from_now(n, unit)` — Ecto's interval helpers are exactly /2, so an
      # off-arity same-named call is an author helper, left alone.
      Map.has_key?(@temporal_swaps, form) and length(args) == 2 ->
        [{:temporal, {@temporal_swaps[form], meta, args}, to_string(form)}]

      # Anything else may still be a scalar-expression operator — the arithmetic swaps and the
      # coalesce drop owned by the shared catalog (`Mutare.Ecto.Scalar.local/1`, which carries
      # its own arity guards). Inner literals are still reached by `lift/4` as usual.
      true ->
        Scalar.local({form, meta, args})
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
  # `:interpolated`, `{:keyword, …}` — marks an argument whose grammar is the macro's own, so it is left
  # raw. We mutate only what the author wrote in a form we understand.
  defp descend_arg?(nil, _index), do: true
  defp descend_arg?(routing, index), do: Enum.at(routing, index) == :expression

  # Build `{family, literal_node, labels}` for each distinct mutated value: drop any candidate equal
  # to the original, then dedup by value while **merging** the kind labels of colliding candidates —
  # so `1`'s `pred` (`n-1` = 0) and its `zero` sentinel collapse to one `0` tagged `["pred", "zero"]`
  # (mirroring core's `Literal`), and a qualifier naming *either* suppresses it. Order-stable.
  defp value_mutants(candidates, original, family) do
    candidates
    |> Enum.reject(fn {value, _kind} -> value == original end)
    |> Enum.reduce([], fn {value, kind}, acc ->
      case List.keyfind(acc, value, 0) do
        nil -> acc ++ [{value, [kind]}]
        {^value, kinds} -> List.keyreplace(acc, value, 0, {value, kinds ++ [kind]})
      end
    end)
    |> Enum.map(fn {value, kinds} -> {family, Mutare.AST.literal(value), kinds} end)
  end
end
