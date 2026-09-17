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

  ## SQL semantics throughout the catalog

  The catalog reuses **none** of Mutare's built-in mutators: the operators look like Elixir's
  but they evaluate under SQL's semantics — three-valued boolean logic for the connectives,
  NULL handling for the predicates, boundary behaviour for the comparisons, the engine's
  division for arithmetic — so an Elixir-semantics mutator would silently drop
  genuinely killable mutants (or emit provably equivalent ones). The in-fragment literal arms are
  implemented here for the same reason: a literal written into a condition is part of the SQL
  the query runs, not interpolated Elixir, so core never traverses it (the clause is raw/`:hosted`). They follow
  core's value conventions — the numeric arms take their off-by-one/zero table and
  `# mutare:ignore` labels from `Mutare.AST.numeric_alternatives/3`, so the two can't drift —
  but the mutations are selected here under SQL semantics. Each is named after the *type* it
  mutates (`integer_literal`, …), never after `fragment(...)`.

  A `^` pin's interior is ordinary Elixir evaluated at runtime, so this catalog never mutates it
  (applying the SQL mutation `^(min * 2)` → `^(min / 2)` would mutate the parameter's Elixir value).
  The walk treats a pin as a leaf, and `islands/1` returns each interior for the calling module
  to pass to core — see `Mutare.Ecto.Island`. Field references (`u.age`) are likewise never mutated.

  ## The families

    * **Comparison** — `>`↔`>=`, `<`↔`<=`, `==`↔`!=`. The `==`/`!=` swap is never "equivalent":
      in SQL both forms exclude `NULL` rows and differ on every concrete value.
    * **Connective** — `and`↔`or`. Genuinely three-valued (a `NULL` operand is neither true nor
      false), so its equivalences differ from Elixir's.
    * **NullPredicate** — `is_nil(x)`↔`not is_nil(x)`, treated as one unit so `not is_nil(x)`
      flips back rather than double-negating. Its argument is descended like any other, but
      `is_nil` observes only *whether* the argument is NULL, so a mutant there is pruned when —
      and only when — it is **known** to be NULL on exactly the original's rows (see
      "What `is_nil` observes" below).
    * **Membership** — `x in ^list`↔`x not in ^list` and `exists(subquery)`↔`not exists(subquery)`
      (unit polarity flips, no double negation), one **element drop** per *distinct* entry of a
      *written* in-list, removing every occurrence (`x in [1, 2, 3]` → `x in [2, 3]`/…; `IN` is
      set membership, so `[1, 1, 2]` shrinks to `[2]`/`[1, 1]`, never to the equivalent
      `[1, 2]`), and `like`↔`ilike` — **dialect-gated** on
      `:postgres` (`ilike` is Postgres-specific; the rest is portable). The `in` operands are
      descended (a swap on the left or a literal in the written list changes which rows match).
      A subquery argument is not descended *as a condition*; its interior is recursed by
      `Mutare.Ecto.Subquery`, each mutant rebuilt into this condition.
    * **Arithmetic** — `+`↔`-`, `*`↔`/`, the shared `Mutare.Ecto.Scalar` catalog (also delivered
      in `select`/`order_by` values); binary forms only.
    * **Coalesce** — `coalesce(x, default)` → `x` (also `Mutare.Ecto.Scalar`): differs exactly
      on the rows where `x` is NULL. Beneath `is_nil` too: `is_nil(coalesce(x, d))` →
      `is_nil(x)` differs on every row where `x` is NULL and `d` is not.
    * **Aggregate** — `sum`↔`avg`, `min`↔`max` (the shared `Mutare.Ecto.Aggregate`), for a
      `having: sum(p.x) > n`. Applied per node by this walk, so a condition is walked **once**
      for every family.
    * **Temporal** — `ago(n, unit)`↔`from_now(n, unit)`: symmetric around *now*, so a comparison
      against them differs only for rows inside that window. The `unit` is structural (below);
      the count keeps its literal mutants.
    * **IntegerLiteral** / **FloatLiteral** — a *non-pinned* numeric literal (`u.age > 18` →
      `19`/`17`/`0`; `2.5` → `3.5`/`1.5`/`0.0`): `n±1` plus the zero sentinel, deduped and never
      equal to the original.
    * **StringLiteral** — `u.name == "ok"` → `""`/`"mutare"`, dropping whichever equals the original.
    * **BooleanLiteral** — `true`↔`false`: a boolean in a fragment is worth flipping exactly when
      it is worth using.
    * **AtomLiteral** — any *other* literal atom → the `:mutare` sentinel (dropped when already
      the sentinel); `nil` is excluded (NULL/absence, no clean swap).

  The string/atom/boolean arms are opt-in (off under the default `families:`) — see the
  `Mutare.Ecto` configuration docs.

  A literal arm is also suppressed at a **structural position** of a known Ecto DSL form, where the
  literal shapes the SQL the builder emits rather than carrying data (a mutant would be a broken
  query, not a live one): the `fragment` template, an interval unit, a cast type, a column,
  binding, or alias name — `structural_position?/1` is the registry, consulted off the
  `{parent_form, arity, index}` the walk threads down. Data literals at every *other* position
  of those forms are still mutated. A **tuple** is classified by position in the same way: at a
  structural position it is a compound cast spec (`{:array, :string}`), skipped whole; anywhere else it is
  Ecto's tuple comparison (`{p.views, p.id} > {1, 2}`), walked like a written list — each element
  a data position of the comparison (`children/2`).

  ## What `is_nil` observes

  `is_nil(x)` reads one bit of `x` per row — whether it is NULL — so a mutant inside `x` that is
  NULL on exactly the original's rows cannot change the predicate: it is equivalent, and pruned.
  That property is claimed only where it is **known**, from one table of per-form NULL rules
  (`nullness/1`):

    * a non-`nil` literal (a written negative number included) is never NULL;
    * `a + b`, `a - b` and `a * b` are NULL exactly when an operand is;
    * `coalesce(a, b)` is NULL exactly when both operands are;
    * `sum`/`avg`/`min`/`max` of `x` is NULL exactly when no input row has a non-NULL `x`.

  Two decisions read that table. A mutant is pruned when it and the node it replaces are both
  never NULL (a literal bump) or follow the same rule over the same operands (`+`→`-`,
  `sum`→`avg`). And the NULL-ness-only observation passes down through a form only while that
  form has a rule: each rule makes the form's NULL-ness a function of its operands' NULL-ness,
  never of their values. Beneath any other form an operand's *value* may decide whether the
  whole is NULL, so the full catalog applies there again.

  Every other form is **unknown**, and an unknown is never pruned:

    * `a / b` — a zero divisor yields NULL on SQLite and MySQL and raises on Postgres, so
      `is_nil(a * b)` → `is_nil(a / b)` is live, and so is a literal inside a divisor;
    * `and`/`or` — three-valued (`NULL and false` is false where `NULL or false` is NULL);
    * `in` and a tuple comparison — NULL or not depending on which values match;
    * a JSON path (`is_nil(p.meta["k"])` — the key picks the element), a `fragment(...)`
      (`is_nil(fragment("NULLIF(?, ?)", p.score, 0))` — the `0` decides which scores read as
      NULL), a subquery, a nested author macro;
    * a `^` pin — ordinary Elixir, free to compute `nil` or a value by any route
      (`^(opts[:min] || default)`), so an island beneath `is_nil` is passed to core like any other.

  A form missing from the table costs an equivalent mutant (`is_nil(p.a > 1)` → `>=`: a scalar
  comparison is NULL exactly when an operand is, but it has no rule here), never a live one.

  ## Traversal

  The traversal is the plugin's one shared walk (`Mutare.Ecto.Walk`, whose author-macro rule
  specifies which nested-call arguments are entered): this module supplies its descent rule
  (`children/2` — the unit predicates, and each child's context: its
  `{parent_form, arity, index}` position and what the enclosing predicate observes of it) and
  two per-node readers over the positions traversed — the catalog (`local/3`, behind
  `mutants/2`) and the island collector (`local_islands/1`, behind `islands/1`) — so the two
  can never traverse different sets of nodes in a condition.
  """

  alias Mutare.Calls
  alias Mutare.Ecto.{Aggregate, Config, Scalar, Subquery, Tag, Walk}

  @behaviour Mutare.Ecto.Vocabulary

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

  # The context the walk threads to every node: its `{parent_form, arity, index}` position (the
  # key the literal arms consult) and what the enclosing predicate observes of it — its `:value`,
  # or beneath an `is_nil` only its `:nullness` (`child_observed/3`). The condition itself has no
  # parent, and its value is what the clause filters by.
  @typep position :: {term(), non_neg_integer(), non_neg_integer()} | nil
  @typep observed :: :value | :nullness
  @typep ctx :: {position(), observed()}
  @root {nil, :value}

  @doc """
  Every single-point mutant of a `where`/`having` condition as self-tagging `Mutare.Ecto.Tag`s, or
  `[]` when the condition has nothing the catalog mutates (a bare boolean column, an
  interpolation). The condition is a **predicate**. A keyword filter (`where: [score: 5]`) is not
  this catalog's syntax — the walk would read a `score: 5` pair as a value tuple, data on both
  sides, and rename the column — so every caller classifies a condition-position value first
  (`Mutare.Ecto.Host.Condition`). One tag per mutatable position, each the full condition with that one
  position swapped, tagged with the SQL family that produced it (so the caller can filter by
  `families:`) **and** the finer label naming the operator/kind it swapped (so a qualified
  `# mutare:ignore[ecto:<]` can suppress just that one). `config` carries `dialects:` — the
  `like`↔`ilike` swap is emitted only under `:postgres`.

  The catalog proper is `local/3` — the mutations for one node, at its `{parent_form, arity, index}`
  position — applied at every position the shared walk (`Mutare.Ecto.Walk`) traverses under this
  catalog's own descent rule (`children/2`), and narrowed beneath an `is_nil` to the mutants not
  known to keep the node's NULL-ness (`observable/3`).
  """
  @spec mutants(Macro.t(), Config.t()) :: [Tag.t()]
  def mutants(condition, %Config{} = config),
    do: Walk.mutants(condition, @root, &children/2, &observable(&1, &2, config))

  @doc """
  Every interpolation **island** (`^expr`) in the condition, as `{interior, rebuild}` pairs —
  `interior` is the pin's Elixir expression and `rebuild.(mutated_interior)` is the full condition
  with exactly that pin's interior replaced (the pin itself kept). The calling module passes
  each interior to core — see `Mutare.Ecto.Island`.

  The islands are a second reader of the **same** positions `mutants/2` reads
  (`local_islands/1` over `Mutare.Ecto.Walk.positions/3`, under the same `children/2`), so a
  caller cannot reach an island the catalog would not have walked past — by construction, not by
  a parallel walk kept in step. So a subquery argument surfaces the pins of the clauses
  `Mutare.Ecto.Subquery` mutates under that wrapper, and the pin itself is the boundary
  (everything beneath it is passed to core for mutation). What the enclosing predicate observes
  never narrows this reader: a pin beneath `is_nil` is an island too, because nothing is known
  about which Elixir mutants keep a parameter's `nil`-ness (see "What `is_nil` observes").
  """
  @spec islands(Macro.t()) :: [{Macro.t(), (Macro.t() -> Macro.t())}]
  def islands(condition) do
    for {node, _ctx, rebuild} <- Walk.positions(condition, @root, &children/2),
        {interior, inner} <- local_islands(node),
        do: {interior, &rebuild.(inner.(&1))}
  end

  # `Mutare.Ecto.Vocabulary`: the operators the swap families mutate (the swap tables' keys) plus
  # the unit and value kinds. The arithmetic operators are `Mutare.Ecto.Scalar`'s, which owns them.
  @impl Mutare.Ecto.Vocabulary
  def variant_labels do
    swap_ops =
      [@comparison_swaps, @connective_swaps, @membership_op_swaps, @temporal_swaps]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&to_string/1)

    swap_ops ++ ~w(in element exists is_nil succ pred zero empty sentinel negate)
  end

  # ── Descent: which nodes of a condition are positions ──────────────────────────────────────
  #
  # The catalog's one descent rule, for `Mutare.Ecto.Walk.positions/3`: from a node, the children
  # the walk continues into, each with its context (`child_ctx/3`) and the splice back into its
  # parent. `mutants/2` and `islands/1` read the positions this rule admits and never descend on
  # their own, so the two agree at every node by construction.

  # A reverse-polarity unit — `not is_nil(x)`, `x not in list`, `not exists(q)` — is ONE position,
  # the outer `not`. The inner predicate is never a position of its own: its polarity flip would
  # offer the double negation (`not not is_nil(x)`), and its islands are read through the `not`
  # (`local_islands/1`). But whatever the predicate itself descends into is still descended —
  # the `is_nil` argument, the `in` operands — each child spliced back inside the written `not`.
  @spec children(Macro.t(), ctx()) :: [Walk.child(ctx())]
  defp children({:not, meta, [inner]} = node, ctx) do
    if unit?(inner) do
      for {child, child_ctx, splice} <- children(inner, ctx),
          do: {child, child_ctx, &{:not, meta, [splice.(&1)]}}
    else
      Walk.structural(node, ctx, &child_ctx/3)
    end
  end

  # `exists`'s argument is a subquery — a query, not this condition's syntax — so it is never
  # entered *as a condition*; `local/3` and `local_islands/1` hand its interior to
  # `Mutare.Ecto.Subquery` instead. (A value-wrapper's `from` — `all(from …)`, `subquery(from …)`
  # — is reached by ordinary descent and recursed the same way; only `exists` is a unit.)
  defp children({:exists, _meta, [_arg]}, _ctx), do: []

  # A tuple — `{left, right}` (a 2-tuple is bare AST) or `{:{}, meta, elements}` (every other
  # size) — plays two roles in a condition, told apart by its position. At a *structural*
  # position it is a compound cast spec — `type(x, {:array, :string})`, `{:parameterized, …}` —
  # whose every literal, at any depth, is the SQL type the builder emits: it stays unentered,
  # which is what keeps a *nested* spec's literals out of reach (the structural-position
  # registry names only a form's direct argument, so a walk into the spec would hand the inner
  # literals a non-structural position). Anywhere else it is a **value tuple**: Ecto's tuple
  # comparison, `{p.views, p.id} > {1, 2}` (SQL's row-value comparison, `(views, id) > (1, 2)`),
  # the one value role Ecto grants a tuple (it is refused outside a comparison against a tuple
  # of the same size). That tuple is transparent syntax like a written list — its elements keep
  # the enclosing comparison's position (`child_position/3`) — so a literal element is data and
  # mutated, a field/arithmetic element is walked, and a pinned element is an island. There is
  # no element drop (unlike an in-list, the two sides must keep one size).
  defp children({:{}, _meta, _elements} = tuple, ctx), do: tuple_children(tuple, ctx)
  defp children({_left, _right} = tuple, ctx), do: tuple_children(tuple, ctx)

  # Everything else — an operator/call (its arguments under the author-macro rule), a written
  # list, a Sourceror block — descends structurally; a `^` pin is a leaf (`Mutare.Ecto.Walk`).
  # That includes `is_nil`: its argument is ordinary syntax, entered like any other, under the
  # narrower observation `child_observed/3` hands it.
  defp children(node, ctx), do: Walk.structural(node, ctx, &child_ctx/3)

  # The tuple rule's one decision (above): a cast spec is a leaf, a value tuple descends.
  defp tuple_children(tuple, {position, _observed} = ctx) do
    if structural_position?(position),
      do: [],
      else: Walk.structural(tuple, ctx, &child_ctx/3)
  end

  # A child's context, from its parent: where it sits, and what is observed of it.
  defp child_ctx(parent, index, {position, observed}),
    do: {child_position(parent, index, position), child_observed(parent, index, observed)}

  # A child's `{parent_form, arity, index}` — the key the literal arms consult
  # (`structural_position?/1`, `json_path_position?/1`). A Sourceror block, a written list and a
  # value tuple (either AST form) are transparent syntax: their elements keep the enclosing
  # *call's* position (the registry is keyed by call-argument positions, and a
  # `json_extract_path` path element's constraints are the path argument's). The top-level
  # condition has no parent (`nil`) and is never structural.
  defp child_position({:__block__, _meta, _args}, _index, position), do: position
  defp child_position({:{}, _meta, _elements}, _index, position), do: position
  defp child_position({form, _meta, args}, index, _position), do: {form, length(args), index}
  defp child_position(_list_or_pair, _index, position), do: position

  # The unit predicates — the ones a written `not` claims as a single position.
  defp unit?({:is_nil, _meta, [_arg]}), do: true
  defp unit?({:in, _meta, [_left, _right]}), do: true
  defp unit?({:exists, _meta, [_arg]}), do: true
  defp unit?(_node), do: false

  # ── What `is_nil` observes: NULL-ness, pruned only where it is known ────────────────────────
  #
  # The moduledoc's "What `is_nil` observes" is the rule; this is its whole implementation. One
  # table (`nullness/1`) says what is known about when a node is NULL; the descent
  # (`child_observed/3`) and the pruning (`observable/3`, via `same_nullness?/2`) both read it
  # and nothing else, so neither can claim a property the other does not.

  # What the enclosing predicate observes of a child. `is_nil` observes only its argument's
  # NULL-ness, whatever was observed of the `is_nil` itself. That narrow observation passes down
  # through a parent only while the parent has a rule — its NULL-ness then depends on its
  # operands' NULL-ness alone. Beneath any other parent (`fragment("NULLIF(?, ?)", x, 0)`,
  # `a / b`, `a and b`, a JSON path, a tuple, a list) the child's value may decide whether the
  # parent is NULL, so its value is observed again.
  @spec child_observed(Macro.t(), non_neg_integer(), observed()) :: observed()
  defp child_observed({:is_nil, _meta, [_arg]}, _index, _observed), do: :nullness
  defp child_observed(_parent, _index, :value), do: :value

  defp child_observed(parent, _index, :nullness),
    do: if(nullness(parent) == :unknown, do: :value, else: :nullness)

  # The catalog as the enclosing predicate can observe it: all of `local/3` where the node's
  # value is observed; where only its NULL-ness is, the mutants **not known** to be NULL on
  # exactly the rows the node is. (A subquery's interior mutants ride `local/3` too, and a query
  # has no rule, so they are never pruned.)
  @spec observable(Macro.t(), ctx(), Config.t()) :: [Tag.t()]
  defp observable(node, {position, :value}, config), do: local(node, position, config)

  defp observable(node, {position, :nullness}, config),
    do: node |> local(position, config) |> Enum.reject(&same_nullness?(node, &1.node))

  # Known to be NULL on exactly the same rows: both never NULL, or the same rule over the same
  # operands. Two unknowns are not the same unknown.
  defp same_nullness?(node, mutant) do
    case {nullness(node), nullness(mutant)} do
      {:never, :never} -> true
      {{rule, operands}, {rule, operands}} -> true
      _unknown -> false
    end
  end

  # What is known about when a node is NULL — `:never`, or `{rule, operands}`: NULL exactly when
  # `:any_operand` is, when `:every_operand` is, or when an aggregate has `:no_input` row whose
  # operand is non-NULL. Every rule depends on the operands' NULL-ness alone, which is what
  # `child_observed/3` relies on. Everything else is `:unknown` — including a **registered
  # macro** wearing one of these names (stamped by the resolve pass; its meaning is its
  # author's, the same ownership test as `Mutare.Ecto.Aggregate`'s ladder), and including `/`,
  # whose zero divisor is NULL on SQLite and MySQL and an error on Postgres.
  @spec nullness(Macro.t()) :: :never | {atom(), [Macro.t()]} | :unknown
  defp nullness({:__block__, _meta, [literal]})
       when (is_number(literal) or is_binary(literal) or is_atom(literal)) and
              not is_nil(literal),
       do: :never

  # A written negative number is the arity-1 `-` over the wrapped literal — sign syntax, the
  # only unary minus Ecto accepts — and `Mutare.AST.literal/1` emits a negative mutant in the
  # same shape.
  defp nullness({:-, _meta, [{:__block__, _literal_meta, [number]}]}) when is_number(number),
    do: :never

  defp nullness({form, _meta, args} = node) when is_atom(form) and is_list(args) do
    if Calls.routed_treatments(node), do: :unknown, else: ecto_nullness(form, args)
  end

  defp nullness(_node), do: :unknown

  defp ecto_nullness(op, [_left, _right] = operands) when op in [:+, :-, :*],
    do: {:any_operand, operands}

  defp ecto_nullness(:coalesce, [_x, _default] = operands), do: {:every_operand, operands}

  defp ecto_nullness(aggregate, [_x] = operands) when aggregate in [:sum, :avg, :min, :max],
    do: {:no_input, operands}

  defp ecto_nullness(_form, _args), do: :unknown

  # ── The catalog: what one position offers ──────────────────────────────────────────────────
  #
  # `local/3` is the SQL catalog proper: the tagged single-point alternatives of **one** node at
  # its position — no descent (that is the walk's), each rebuilt into the whole condition by
  # `Mutare.Ecto.Walk.mutants/4`.

  # NullPredicate, as a unit. `not is_nil(x)` → `is_nil(x)`: flip the whole predicate (the inner
  # `is_nil` is not a position — `children/2` — so it never also offers `is_nil` → `not is_nil`,
  # a redundant `not not is_nil(x)`). Both directions are tagged `"is_nil"` (`not is_nil` has a
  # space — not a wire-safe label), so `# mutare:ignore[ecto:is_nil]` suppresses the
  # null-predicate flip whichever way it points. The argument's own mutants are the walk's.
  defp local({:not, _meta, [{:is_nil, _, [_arg]} = inner]}, _position, _config),
    do: [Tag.new(:null_predicate, inner, "is_nil")]

  # `is_nil(x)` → `not is_nil(x)`, clean meta on the fresh `not`.
  defp local({:is_nil, _meta, [_arg]} = node, _position, _config),
    do: [Tag.new(:null_predicate, {:not, [], [node]}, "is_nil")]

  # Membership. `x not in list` → `x in list`: flip the whole predicate as a unit (no double
  # negation), plus the element drops of a written list, rebuilt inside the `not` so each stays a
  # single-point variant of the full predicate. The operand descent (an arithmetic swap on the
  # left, a literal bump inside the written list) is the walk's, spliced through the `not` by
  # `children/2`. Both polarity directions are tagged `"in"` (`not in` has a space), so
  # `# mutare:ignore[ecto:in]` names the polarity flip.
  defp local({:not, meta, [{:in, _imeta, [_l, _r]} = inner]}, _position, _config),
    do: [Tag.new(:membership, inner, "in") | rewrap(element_drops(inner), meta)]

  # `x in list` → `x not in list` (clean meta on the fresh `not`), plus the element drops of a
  # written list — a pinned `^list` or a field reference yields nothing.
  defp local({:in, _meta, [_l, _r]} = node, _position, _config),
    do: [Tag.new(:membership, {:not, [], [node]}, "in") | element_drops(node)]

  # Existence polarity, as a unit (the subquery cousin of the `in` flip), **plus** the subquery's
  # own interior mutants. `not exists(subquery)` → `exists(subquery)` flips the whole predicate
  # (`"exists"` — `not exists` has a space, not a wire-safe label — so
  # `# mutare:ignore[ecto:exists]` names the flip whichever way it points); the interior mutants
  # come from `Mutare.Ecto.Subquery` in `:existence` mode, each re-wrapped inside the `not exists`.
  defp local({:not, not_meta, [{:exists, ex_meta, [arg]} = inner]}, _position, config) do
    interior =
      for tag <- Subquery.interior_mutants(arg, config, :existence),
          do: Tag.map_node(tag, &{:not, not_meta, [{:exists, ex_meta, [&1]}]})

    # mutare:ignore[operand_swap] equivalent — the polarity flip and the interior set are independent, consumed as a set
    [Tag.new(:membership, inner, "exists") | interior]
  end

  # `exists(subquery)` → `not exists(subquery)` (clean meta on the fresh `not`), plus the subquery's
  # interior mutants in `:existence` mode, each re-wrapped inside the `exists`.
  defp local({:exists, ex_meta, [arg]} = node, _position, config) do
    interior =
      for tag <- Subquery.interior_mutants(arg, config, :existence),
          do: Tag.map_node(tag, &{:exists, ex_meta, [&1]})

    # mutare:ignore[operand_swap] equivalent — the polarity flip and the interior set are independent, consumed as a set
    [Tag.new(:membership, {:not, [], [node]}, "exists") | interior]
  end

  # An interpolation island (`^expr`) is never this catalog's (see the moduledoc): it contributes
  # nothing here, and `islands/1` collects its interior for the core sub-contract instead.
  defp local({:^, _meta, _args}, _position, _config), do: []

  # A literal (int/float/string/bool/atom) written directly into the fragment (Sourceror-wrapped):
  # skipped at a *structural* position (`structural_position?/1`, off the position
  # `child_position/3` threads down), constrained at a JSON path position, and otherwise mutated
  # by type via `literal_mutants/1`. A *pinned* `^value` is not this shape and never reaches here.
  defp local({:__block__, _meta, [lit]} = node, position, _config)
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
  defp local({:__block__, _meta, _args}, _position, _config), do: []

  # A tuple in its `{:{}, …}` form has no swap of its own: a value tuple's elements are the
  # walk's (`children/2`), a cast spec's are structural. (The 2-tuple form is bare AST, not a
  # call, and falls to the catch-all below.)
  defp local({:{}, _meta, _elements}, _position, _config), do: []

  # An operator/connective (atom form): its own swap (if any). A bare inline subquery `from(...)`
  # (the argument of a value-wrapper — `all`/`any`/`subquery`/`in` — reached by the operand descent)
  # has no swap of its own, but `Subquery` recurses its interior in `:value` mode; every other
  # node's `interior_mutants` is `[]`.
  defp local({form, meta, args} = node, _position, config) when is_atom(form) and is_list(args) do
    # mutare:ignore[operand_swap] swap/subquery order is irrelevant — mutants are consumed as a set
    swap(form, meta, args, config) ++ Subquery.interior_mutants(node, config, :value)
  end

  # A non-atom-form node (e.g. a `u.age` field access, whose form is the `{:., …}` dot tuple, or a
  # qualified `Ecto.Query.from(...)` subquery): no swap of its own — its arguments are the walk's,
  # exactly as core's analyzer recurses — but a qualified subquery's interior is offered in
  # `:value` mode.
  defp local({_form, _meta, args} = node, _position, config) when is_list(args),
    do: Subquery.interior_mutants(node, config, :value)

  # Variables, a block's bare payload, a 2-tuple (no swap of its own — its elements are the
  # walk's), bare atoms: no catalog target (interpolations are core's; the `in`/`like` membership
  # forms are handled by their own clauses above).
  defp local(_node, _position, _config), do: []

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

  # `exists`'s argument is a unit (`children/2`), so its interior islands are surfaced here (via
  # `Mutare.Ecto.Subquery`), each rebuild re-wrapped inside the `exists`.
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

  # Membership set shrink: one mutant per **distinct** element of a **written** in-list, each
  # dropping every occurrence of that element (`x in [1, 2, 3]` → `x in [2, 3]` / `[1, 3]` /
  # `[1, 2]`) — "does any test pin this member?". SQL `IN` is set membership, so the written
  # list denotes the set of its distinct values (`[1, 1, 2]` is `{1, 2}`): a drop that left
  # another occurrence of the same value (`[1, 1, 2]` → `[1, 2]`) would leave the set unchanged —
  # equivalent to the original by construction — so `[1, 1, 2]` shrinks exactly to `[2]` and
  # `[1, 1]`. Two elements are one member when they are the same written expression
  # (structurally, source metadata ignored): `1`/`1`, `^a`/`^a`, `u.x`/`u.x`. Only a literal list
  # the author wrote qualifies: a pinned `^list`, a field reference, or a subquery right-hand
  # side has no written elements to drop. A singleton drops to `x in []` (constantly false —
  # still valid, trivially killable SQL). Tagged `"element"` so `# mutare:ignore[ecto:element]`
  # names the drops apart from the polarity flip.
  defp element_drops({:in, meta, [l, {:__block__, lmeta, [elems]}]}) when is_list(elems) do
    keys = Enum.map(elems, &Sourceror.strip_meta/1)

    for key <- Enum.uniq(keys) do
      kept = for {elem, k} <- Enum.zip(elems, keys), k != key, do: elem
      Tag.new(:membership, {:in, meta, [l, {:__block__, lmeta, [kept]}]}, "element")
    end
  end

  defp element_drops(_node), do: []

  # Rebuild each descent/drop mutant of a reverse-polarity unit's inner predicate back inside the
  # written `not`, keeping the tag — so the emitted node is the full condition, single-point.
  defp rewrap(mutants, meta),
    do: Enum.map(mutants, &Tag.map_node(&1, fn m -> {:not, meta, [m]} end))

  # IntegerLiteral: core's own off-by-one/zero table (`Mutare.AST.numeric_alternatives/3`: `n±1`
  # plus the zero sentinel, deduped and never equal to `n`, a collapse carrying both labels).
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

  # BooleanLiteral: `true` ↔ `false` (core's `Literal` boolean arm); `nil` is not a boolean.
  defp literal_mutants({:__block__, _meta, [bool]}) when is_boolean(bool),
    do: [Tag.new(:boolean_literal, Mutare.AST.literal(not bool), "negate")]

  # AtomLiteral: any other literal atom → the `:mutare` sentinel (core's `AtomLiteral` convention),
  # dropped when the atom already is the sentinel; `true`/`false` never reach here — the
  # BooleanLiteral clause above claims them by clause order.
  defp literal_mutants({:__block__, _meta, [atom]})
       when is_atom(atom) and not is_nil(atom) and atom != @atom_sentinel,
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

  # The registry of known Ecto DSL forms and the argument positions whose literal is *structural*
  # — part of the SQL the query builder emits, not data (see the moduledoc) — keyed off the
  # `{parent_form, arity, index}` the walk threads down (`child_position/3`). The top-level
  # condition has no parent (`nil`) and is never structural.
  #
  #   * `fragment(template, …)`        — arg 0 is the SQL template (any arity)
  #   * `datetime_add(_, _, interval)` — arg 2 is the interval unit
  #   * `date_add(_, _, interval)`     — arg 2 is the interval unit
  #   * `from_now(_, interval)`        — arg 1 is the interval unit
  #   * `ago(_, interval)`             — arg 1 is the interval unit
  #   * `type(_, type)`                — arg 1 is the cast type
  #   * `field(_, name)`               — arg 1 is the column name (a mutated name is a wrong —
  #                                      usually nonexistent — column, not a live mutant)
  #   * `count(_, :distinct)`          — arg 1 is the distinctness modifier, the only value Ecto's
  #                                      `count/2` accepts (it pattern-matches the literal atom),
  #                                      so any swap is an unsupported-expression raise, never a
  #                                      live mutant
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
  defp structural_position?({:count, 2, 1}), do: true
  defp structural_position?({:as, 1, 0}), do: true
  defp structural_position?({:parent_as, 1, 0}), do: true
  defp structural_position?({:selected_as, 1, 0}), do: true
  defp structural_position?({:selected_as, 2, 1}), do: true
  defp structural_position?(_position), do: false

  # The atom-form node's own single swap, tagged by family **and** by the operator it swaps (the
  # source `form`, e.g. `<`) — so `# mutare:ignore[ecto:<]` names just this swap. `like`↔`ilike` is
  # dialect-gated (Postgres); comparison/connective are portable.
  defp swap(form, meta, args, config) do
    cond do
      Map.has_key?(@comparison_swaps, form) ->
        [Tag.new(:comparison, {@comparison_swaps[form], meta, args}, to_string(form))]

      Map.has_key?(@connective_swaps, form) ->
        [Tag.new(:connective, {@connective_swaps[form], meta, args}, to_string(form))]

      Map.has_key?(@membership_op_swaps, form) and Config.dialect_enabled?(config, [:postgres]) ->
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
