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
      families (arithmetic, the aggregates, the literal arms) preserve an expression's NULL-ness —
      they change the value, never whether it is NULL — so their mutants are *provably equivalent* inside the one
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
    * **Aggregate** — `sum`↔`avg`, `min`↔`max` (the shared `Mutare.Ecto.Aggregate`, also
      delivered in `select`/`order_by` values), for a `having: sum(p.x) > n`. Applied per node by
      this walk, so a condition is walked **once** for every family — and so the `is_nil` rule
      covers it: a value aggregate is NULL exactly when it has no non-NULL input, so
      `is_nil(sum(x))` → `is_nil(avg(x))` is unconditionally equivalent and never offered.
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
  raw/`:hosted`). They follow core's value conventions — the numeric arms take their
  off-by-one/zero table and `# mutare:ignore` labels straight from `Mutare.AST.numeric_alternatives/3`,
  so the two can't drift — but are decided here under SQL semantics.
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
  generation (`Mutare.Analyze.expression_mutations/3` — see `Mutare.Ecto.Island`).

  A literal arm is also suppressed at a **structural position** of a known Ecto DSL form, where the
  literal shapes the SQL the builder emits rather than carrying data (mutating it yields a broken
  query, not a live mutant): the `fragment` template (arg 0), the interval unit of
  `datetime_add`/`date_add` (arg 2) and `from_now`/`ago` (arg 1), the cast type of `type/2`
  (arg 1), the column name of `field/2` (arg 1), the binding name of `as/1`/`parent_as/1`
  (arg 0), and the alias name of `selected_as/1,2` (its last argument). The walk threads each
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

  The traversal itself is the plugin's one shared walk (`Mutare.Ecto.Walk`): this module supplies
  its descent rule (`children/2` — the unit predicates, the `{parent_form, arity, index}`
  position) and two per-node readers over the positions it admits — the catalog (`local/3`,
  behind `mutants/2`) and the island collector (`local_islands/1`, behind `islands/1`) — so the
  two can never disagree about which nodes a condition exposes.
  """

  alias Mutare.Ecto.{Aggregate, Config, Scalar, Subquery, Tag, Walk}

  # Each operator's single SQL-meaningful swap, by family. `:count`-style arity-changing or
  # NULL-equivalent rewrites are deliberately absent. The `like`/`ilike`
  # case-sensitivity swap is dialect-gated (Postgres) in `swap/4`.
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
  Every single-point mutant of a `where`/`having` condition as self-tagging `Mutare.Ecto.Tag`s, or
  `[]` when the condition has nothing the catalog mutates (a bare boolean column, a keyword-shorthand
  value, an interpolation). One tag per mutatable position, each the full condition with that one
  position swapped, tagged with the SQL family that produced it (so the caller can filter by
  `families:`) **and** the finer label naming the operator/kind it swapped (so a qualified
  `# mutare:ignore[ecto:<]` can suppress just that one). `opts` carries `dialects:` — the
  `like`↔`ilike` swap is emitted only under `:postgres`.

  The catalog proper is `local/3` — what one node offers, at its `{parent_form, arity, index}`
  position — read over every position the shared walk (`Mutare.Ecto.Walk`) admits under this
  catalog's own descent rule (`children/2`).
  """
  @spec mutants(Macro.t(), keyword() | Config.t()) :: [Tag.t()]
  def mutants(condition, opts \\ []),
    do: Walk.mutants(condition, nil, &children/2, &local(&1, &2, opts))

  @doc """
  Every interpolation **island** (`^expr`) in the condition, as `{interior, rebuild}` pairs —
  `interior` is the pin's Elixir expression and `rebuild.(mutated_interior)` is the full condition
  with exactly that pin's interior replaced (the pin itself kept). The condition's owner — the
  selector host for a hosted `where`/`having`, `Mutare.Ecto.Dynamic` for a free-standing
  `dynamic` — feeds each interior to generation over the run's full spec set
  (`Mutare.Analyze.expression_mutations/3`) and relays the rebuilds through its own delivery
  with `producer:` attribution (`Mutare.Ecto.Island.subcontracted/3`), so a pin interior
  is analyzed exactly like top-level Elixir — core's families reason about the Elixir, and the
  plugin's whole surface reasons about any Ecto inside it: an inner `dynamic(...)` literal
  mutates once, under SQL semantics, and an inner `from`'s hosted conditions are lowered by
  core's collect to whole-call rebuilds — while delivery stays the caller's (the host's weave,
  or the whole-call in-place rewrite).

  The islands are a second reader of the **same** positions `mutants/2` reads
  (`local_islands/1` over `Mutare.Ecto.Walk.positions/3`, under the same `children/2`), so a
  caller cannot reach an island the catalog would not have walked past — by construction, not by
  a parallel walk kept in step: an `is_nil` argument is never entered (value mutants of a
  parameter preserve its NULL-ness, so they are provably equivalent inside the one predicate that
  observes only NULL-ness); an `exists`/`all`/`any`/`in` subquery argument surfaces the pins inside
  the subquery's own mutated clauses (via `Mutare.Ecto.Subquery`, each rebuilt back into this
  condition) — its `where`/`having` conditions, plus a value-wrapper's observed `select` (never an
  EXISTS select, unobserved) — those interiors are ordinary Elixir, core's to mutate, exactly like a
  top-level pin; a nested author macro's argument is entered only when routed `:expression` (or not a
  macro at all); and the pin itself is a boundary — the sub-contract owns everything beneath it,
  including any nested pin (`^` does not nest in Ecto).
  """
  @spec islands(Macro.t()) :: [{Macro.t(), (Macro.t() -> Macro.t())}]
  def islands(condition) do
    for {node, _position, rebuild} <- Walk.positions(condition, nil, &children/2),
        {interior, inner} <- local_islands(node),
        do: {interior, &rebuild.(inner.(&1))}
  end

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

    # Sort for determinism: `Map.keys` iteration order over atom keys is unspecified and varies
    # with runtime atom-table state. The result is consumed as a set of known labels, so a
    # canonical order changes nothing but makes the vocabulary stable run to run.
    Enum.sort(swap_ops ++ ~w(in element exists is_nil succ pred zero empty sentinel negate))
  end

  # ── Descent: which nodes of a condition are positions ──────────────────────────────────────
  #
  # The catalog's one descent rule, for `Mutare.Ecto.Walk.positions/3`: from a node, the children
  # the walk continues into, each with its `{parent_form, arity, index}` position and the splice
  # back into its parent. `mutants/2` and `islands/1` read the positions this rule admits and
  # never descend on their own, so the two agree at every node by construction.

  # A reverse-polarity unit — `not is_nil(x)`, `x not in list`, `not exists(q)` — is ONE position,
  # the outer `not`. The inner predicate is never a position of its own: its polarity flip would
  # offer the double negation (`not not is_nil(x)`), and its islands are read through the `not`
  # (`local_islands/1`). But whatever the predicate itself descends into is still descended —
  # the `in` operands: an arithmetic swap on the left or a literal in a written list changes
  # which rows match — each child spliced back inside the written `not`.
  defp children({:not, meta, [inner]} = node, position) do
    if unit?(inner) do
      for {child, child_position, splice} <- children(inner, position),
          do: {child, child_position, &{:not, meta, [splice.(&1)]}}
    else
      Walk.structural(node, position, &child_position/3)
    end
  end

  # `is_nil`'s argument is never entered — and not because there is nothing there
  # (`is_nil(u.a + u.b)` is legal SQL): the value families preserve an expression's NULL-ness (an
  # arithmetic/aggregate/literal swap changes the value, never whether it is NULL), so inside a predicate
  # that asks *only* about NULL-ness their mutants are provably equivalent — and the coalesce
  # drop, the one NULL-ness-changing mutation, would only fire under an `is_nil` the author
  # already wrote constantly false (`is_nil(coalesce(x, d))` is false for every row when `d` is
  # non-NULL). The same holds of a pin's value mutants, so no island surfaces beneath it either.
  defp children({:is_nil, _meta, [_arg]}, _position), do: []

  # `exists`'s argument is a subquery — a query, not this condition's syntax — so it is never
  # entered *as a condition*; its **interior** is recursed by `Mutare.Ecto.Subquery` instead, from
  # `local/3` (its mutants) and `local_islands/1` (its pins). (A value-wrapper's `from` —
  # `all(from …)`, `subquery(from …)` — is reached by ordinary descent, and `local/3` recurses it
  # the same way; only `exists` is a unit.)
  defp children({:exists, _meta, [_arg]}, _position), do: []

  # A 2-tuple is not condition syntax the catalog speaks. The one place it appears is a compound
  # cast spec — `type(x, {:array, :string})`, `{:parameterized, …}` — whose every literal is
  # structural, and leaving the tuple unentered is what keeps a *nested* spec's literals out of
  # reach: the structural-position registry names only a form's direct argument.
  defp children({_left, _right}, _position), do: []

  # Everything else — an operator/call (its arguments under the author-macro rule), a written
  # list, a Sourceror block — descends structurally; a `^` pin is a leaf (`Mutare.Ecto.Walk`).
  defp children(node, position), do: Walk.structural(node, position, &child_position/3)

  # A child's `{parent_form, arity, index}` — the key the literal arms consult
  # (`structural_position?/1`, `json_path_position?/1`). A Sourceror block and a written list are
  # transparent syntax: their elements keep the enclosing *call's* position (the registry is keyed
  # by call-argument positions, and a `json_extract_path` path element's constraints are the path
  # argument's). The top-level condition has no parent (`nil`) and is never structural.
  defp child_position({:__block__, _meta, _args}, _index, position), do: position
  defp child_position({form, _meta, args}, index, _position), do: {form, length(args), index}
  defp child_position(_list, _index, position), do: position

  # The unit predicates — the ones a written `not` claims as a single position.
  defp unit?({:is_nil, _meta, [_arg]}), do: true
  defp unit?({:in, _meta, [_left, _right]}), do: true
  defp unit?({:exists, _meta, [_arg]}), do: true
  defp unit?(_node), do: false

  # ── The catalog: what one position offers ──────────────────────────────────────────────────
  #
  # `local/3` is the SQL catalog proper: the tagged single-point alternatives of **one** node at
  # its position — no descent (that is the walk's), each rebuilt into the whole condition by
  # `Mutare.Ecto.Walk.mutants/4`.

  # NullPredicate, as a unit. `not is_nil(x)` → `is_nil(x)`: flip the whole predicate (the inner
  # `is_nil` is not a position — `children/2` — so it never also offers `is_nil` → `not is_nil`,
  # a redundant `not not is_nil(x)`).
  # Both directions are tagged `"is_nil"` (`not is_nil` has a space — not a wire-safe label), so
  # `# mutare:ignore[ecto:is_nil]` suppresses the null-predicate flip whichever way it points.
  defp local({:not, _meta, [{:is_nil, _, [_arg]} = inner]}, _position, _opts),
    do: [Tag.new(:null_predicate, inner, "is_nil")]

  # `is_nil(x)` → `not is_nil(x)`, clean meta on the fresh `not`. (Why its argument is never
  # descended: `children/2`.)
  defp local({:is_nil, _meta, [_arg]} = node, _position, _opts),
    do: [Tag.new(:null_predicate, {:not, [], [node]}, "is_nil")]

  # Membership. `x not in list` → `x in list`: flip the whole predicate as a unit (no double
  # negation), plus the element drops of a written list, rebuilt inside the `not` so each stays a
  # single-point variant of the full predicate. The operand descent (an arithmetic swap on the
  # left, a literal bump inside the written list) is the walk's, spliced through the `not` by
  # `children/2`. Both polarity directions are tagged `"in"` (`not in` has a space), so
  # `# mutare:ignore[ecto:in]` names the polarity flip.
  defp local({:not, meta, [{:in, _imeta, [_l, _r]} = inner]}, _position, _opts),
    do: [Tag.new(:membership, inner, "in") | rewrap(element_drops(inner), meta)]

  # `x in list` → `x not in list` (clean meta on the fresh `not`), plus the element drops of a
  # written list — a pinned `^list` or a field reference yields nothing.
  defp local({:in, _meta, [_l, _r]} = node, _position, _opts),
    do: [Tag.new(:membership, {:not, [], [node]}, "in") | element_drops(node)]

  # Existence polarity, as a unit (the subquery cousin of the `in` flip — SQL's other membership
  # predicate), **plus** the subquery's own interior mutants. `not exists(subquery)` →
  # `exists(subquery)` flips the whole predicate (`"exists"` — `not exists` has a space, not a
  # wire-safe label — so `# mutare:ignore[ecto:exists]` names the flip whichever way it points);
  # the interior mutants come from `Mutare.Ecto.Subquery` in `:existence` mode (its `select` is
  # unobserved by EXISTS, so it is suppressed there), each re-wrapped inside the `not exists`.
  defp local({:not, not_meta, [{:exists, ex_meta, [arg]} = inner]}, _position, opts) do
    interior =
      for tag <- Subquery.interior_mutants(arg, opts, :existence),
          do: Tag.map_node(tag, &{:not, not_meta, [{:exists, ex_meta, [&1]}]})

    # mutare:ignore[operand_swap] equivalent — the polarity flip and the interior set are independent, consumed as a set
    [Tag.new(:membership, inner, "exists") | interior]
  end

  # `exists(subquery)` → `not exists(subquery)` (clean meta on the fresh `not`), plus the subquery's
  # interior mutants in `:existence` mode, each re-wrapped inside the `exists`.
  defp local({:exists, ex_meta, [arg]} = node, _position, opts) do
    interior =
      for tag <- Subquery.interior_mutants(arg, opts, :existence),
          do: Tag.map_node(tag, &{:exists, ex_meta, [&1]})

    # mutare:ignore[operand_swap] equivalent — the polarity flip and the interior set are independent, consumed as a set
    [Tag.new(:membership, {:not, [], [node]}, "exists") | interior]
  end

  # An interpolation island (`^expr`): ordinary Elixir evaluated at runtime and bound as a query
  # parameter — never SQL for this catalog to reason about (a swap here changes the *parameter's*
  # Elixir value/type under an SQL rationale). The catalog contributes nothing, and the walk never
  # enters it; `islands/1` collects the interior for the host's core sub-contract instead.
  defp local({:^, _meta, _args}, _position, _opts), do: []

  # A literal (int/float/string/bool/atom) written directly into the fragment (Sourceror-wrapped).
  # At a *structural* position of a known Ecto DSL form — the `fragment` template, an interval unit
  # of `datetime_add`/`date_add`/`from_now`/`ago`, or the cast type of `type/2` — the literal is
  # part of the SQL the builder emits, not data: mutating it yields a broken query, never a live
  # mutant, so it is skipped (`structural_position?/1` consults the registry, off the
  # `{parent_form, arity, index}` the walk threads down — `child_position/3`). Elsewhere each type
  # emits its own SQL-safe, labelled mutants via `literal_mutants/1`. A *pinned* `^value` is not
  # this shape and never reaches here.
  defp local({:__block__, _meta, [lit]} = node, position, _opts)
       when is_integer(lit) or is_float(lit) or is_binary(lit) or is_atom(lit) do
    cond do
      structural_position?(position) -> []
      json_path_position?(position) -> json_path_mutants(node)
      true -> literal_mutants(node)
    end
  end

  # Any other Sourceror block — the wrapper around a written list or a tuple — is transparent
  # syntax with no swap of its own; the walk threads its position through to the payload
  # (`child_position/3`), so a written in-list's literals are fragment SQL exactly like a bare one.
  defp local({:__block__, _meta, _args}, _position, _opts), do: []

  # An operator/connective (atom form): its own swap (if any). A bare inline subquery `from(...)`
  # (the argument of a value-wrapper — `all`/`any`/`subquery`/`in` — reached by the operand descent)
  # has no swap of its own, but `Subquery` recurses its interior in `:value` mode; every other
  # node's `interior_mutants` is `[]`.
  defp local({form, meta, args} = node, _position, opts) when is_atom(form) and is_list(args) do
    # mutare:ignore[operand_swap] swap/subquery order is irrelevant — mutants are consumed as a set
    swap(form, meta, args, opts) ++ Subquery.interior_mutants(node, opts, :value)
  end

  # A non-atom-form node (e.g. a `u.age` field access, whose form is the `{:., …}` dot tuple, or a
  # qualified `Ecto.Query.from(...)` subquery): no swap of its own — its arguments are the walk's,
  # exactly as core's analyzer recurses — but a qualified subquery's interior is offered in
  # `:value` mode.
  defp local({_form, _meta, args} = node, _position, opts) when is_list(args),
    do: Subquery.interior_mutants(node, opts, :value)

  # Variables, a block's bare payload, 2-tuples, bare atoms: no catalog target (interpolations are
  # core's; the `in`/`like` membership forms are handled by their own clauses above).
  defp local(_node, _position, _opts), do: []

  # ── The islands: what one position hands to core ───────────────────────────────────────────
  #
  # The second reader of the walk's positions (`islands/1`): a pin's interior, kept inside its
  # pin; and, from a subquery wrapper, the pins inside the subquery's own mutated clauses
  # (`Mutare.Ecto.Subquery`), each rebuilt back into the wrapper. Everything else yields nothing.

  defp local_islands({:^, meta, [interior]}), do: [{interior, &{:^, meta, [&1]}}]

  # A reverse-polarity unit's islands are its predicate's, rebuilt inside the written `not` —
  # the mirror of `children/2`, which splices the predicate's descent through the `not` the same
  # way (the predicate itself is not a position, so nothing else reads it). A generic `not` over
  # a condition has no pin or subquery of its own.
  defp local_islands({:not, meta, [inner]}) do
    if unit?(inner),
      do:
        for(
          {interior, rebuild} <- local_islands(inner),
          do: {interior, &{:not, meta, [rebuild.(&1)]}}
        ),
      else: []
  end

  # `exists`'s argument is a subquery whose own condition pins **are** ordinary Elixir, core's to
  # mutate — so surface its interior islands (via `Mutare.Ecto.Subquery`) and re-wrap each rebuild
  # inside the `exists`. (A bare inline `from` argument only; a `subquery(var)`/scalar `from`
  # yields nothing.)
  defp local_islands({:exists, ex_meta, [arg]}) do
    for {interior, rebuild} <- Subquery.interior_islands(arg, :existence),
        do: {interior, &{:exists, ex_meta, [rebuild.(&1)]}}
  end

  # A bare inline subquery `from(...)` (a value-wrapper's argument, reached by the operand descent)
  # surfaces its interior condition pins through `Subquery`; every other call's `interior_islands`
  # is `[]`.
  defp local_islands({_form, _meta, args} = node) when is_list(args),
    do: Subquery.interior_islands(node, :value)

  # Variables, field references, literals: no pin can hide here.
  defp local_islands(_node), do: []

  # Membership set shrink: one mutant per element of a **written** in-list, each dropping that
  # single element (`x in [1, 2, 3]` → `x in [2, 3]` / `[1, 3]` / `[1, 2]`) — "does any test pin
  # this member?". Only a literal list the author wrote qualifies: a pinned `^list`, a field
  # reference, or a subquery right-hand side has no written elements to drop. A singleton drops
  # to `x in []` (constantly false — still valid, trivially killable SQL). Tagged `"element"`
  # so `# mutare:ignore[ecto:element]` names the drops apart from the polarity flip.
  defp element_drops({:in, meta, [l, {:__block__, lmeta, [elems]}]}) when is_list(elems) do
    for index <- 0..(length(elems) - 1)//1 do
      dropped = {:__block__, lmeta, [List.delete_at(elems, index)]}
      Tag.new(:membership, {:in, meta, [l, dropped]}, "element")
    end
  end

  defp element_drops(_node), do: []

  # Rebuild each descent/drop mutant of a reverse-polarity unit's inner predicate back inside the
  # written `not`, keeping the tag — so the emitted node is the full condition, single-point.
  defp rewrap(mutants, meta),
    do: Enum.map(mutants, &Tag.map_node(&1, fn m -> {:not, meta, [m]} end))

  # IntegerLiteral: an integer literal written into the fragment (Sourceror-wrapped). Core's own
  # off-by-one/zero table (`Mutare.AST.numeric_alternatives/3`: `n±1` plus the zero sentinel,
  # deduped and never equal to `n`, a collapse carrying both labels) — delivered here because core
  # can't reach it: the clause is raw.
  defp literal_mutants({:__block__, _meta, [int]}) when is_integer(int),
    do: int |> Mutare.AST.numeric_alternatives(1, 0) |> value_mutants(:integer_literal)

  # FloatLiteral: the same table with core's `FloatLiteral` step and sentinel (`1.0`/`0.0`).
  defp literal_mutants({:__block__, _meta, [f]}) when is_float(f),
    do: f |> Mutare.AST.numeric_alternatives(1.0, 0.0) |> value_mutants(:float_literal)

  # StringLiteral: a plain string literal → the empty string (`empty`) and the `"mutare"` sentinel
  # (core's `StringLiteral` convention), dropping whichever already equals the original — so a
  # typical string yields two mutants. An interpolated string is a `<<>>` node, not this `:__block__`
  # shape, so it is left to core upstream.
  defp literal_mutants({:__block__, _meta, [s]}) when is_binary(s) do
    [{"", ["empty"]}, {@string_sentinel, ["sentinel"]}]
    |> Enum.reject(fn {value, _labels} -> value == s end)
    |> value_mutants(:string_literal)
  end

  # BooleanLiteral: `true` ↔ `false` (core's `Literal` boolean arm). Not aimed at direct boolean
  # comparisons (rarely idiomatic), but at a boolean used elsewhere in a fragment — worth mutating
  # exactly when it is worth using. `nil` is *not* a boolean and is left alone (NULL/absence).
  defp literal_mutants({:__block__, _meta, [bool]}) when is_boolean(bool),
    do: [Tag.new(:boolean_literal, Mutare.AST.literal(not bool), "negate")]

  # AtomLiteral: any other literal atom → the `:mutare` sentinel (core's `AtomLiteral` convention),
  # dropped when the atom already is the sentinel. `true`/`false` are BooleanLiteral's (above) and
  # `nil` is excluded — it is NULL/absence, with no clean swap.
  defp literal_mutants({:__block__, _meta, [atom]})
       # mutare:ignore[literal] equivalent — the preceding is_boolean/1 clause already claims every true/false atom, so by clause order neither value can ever reach this guard regardless of which of the two is named here
       when is_atom(atom) and atom not in [true, false, nil] and atom != @atom_sentinel,
       do: [Tag.new(:atom_literal, Mutare.AST.literal(@atom_sentinel), "sentinel")]

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
    int
    |> Mutare.AST.numeric_alternatives(1, 0)
    |> Enum.filter(fn {value, _labels} -> value >= 0 end)
    |> value_mutants(:integer_literal)
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
  # `{parent_form, arity, index}` the walk threads down (`child_position/3`). The top-level condition has no
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
  defp swap(form, meta, args, opts) do
    cond do
      Map.has_key?(@comparison_swaps, form) ->
        [Tag.new(:comparison, {@comparison_swaps[form], meta, args}, to_string(form))]

      Map.has_key?(@connective_swaps, form) ->
        [Tag.new(:connective, {@connective_swaps[form], meta, args}, to_string(form))]

      Map.has_key?(@membership_op_swaps, form) and Config.dialect_enabled?(opts, [:postgres]) ->
        [Tag.new(:membership, {@membership_op_swaps[form], meta, args}, to_string(form))]

      # `ago(n, unit)` ↔ `from_now(n, unit)` — Ecto's interval helpers are exactly /2, so an
      # off-arity same-named call is an author helper, left alone.
      Map.has_key?(@temporal_swaps, form) and length(args) == 2 ->
        [Tag.new(:temporal, {@temporal_swaps[form], meta, args}, to_string(form))]

      # Anything else may still be a value-expression form owned by a shared per-node catalog —
      # the arithmetic swaps and the coalesce drop (`Mutare.Ecto.Scalar.local/1`, which carries
      # its own arity guards) or an aggregate's ladder swap (`Mutare.Ecto.Aggregate.local/1`, for
      # a `having: sum(p.x) > n`). A node matches at most one of the two, so at most one list is
      # ever non-empty. Inner literals are still reached by the walk as usual.
      true ->
        # mutare:ignore[operand_swap] equivalent — a node matches at most one of the two catalogs, so at most one list is non-empty and concatenation order is unobservable
        Scalar.local({form, meta, args}) ++ Aggregate.local({form, meta, args})
    end
  end

  # Tag each `{value, labels}` alternative as a `family` literal mutant. The labels ride as the
  # list the table hands over (`["succ"]`; a collapse's `["pred", "zero"]`, which either qualifier
  # suppresses) — the value families' label shape, distinct from an operator swap's bare `"<"`.
  defp value_mutants(alternatives, family),
    do:
      for({value, labels} <- alternatives, do: Tag.new(family, Mutare.AST.literal(value), labels))
end
