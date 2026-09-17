defmodule Mutare.Ecto.Subquery do
  @moduledoc false
  # Recurses the plugin's **own** SQL catalogs into the interior of a subquery that appears inside a
  # `where`/`having` condition — `exists(from …)`, `p.x >= all(from …)`, `p.x > subquery(from …)`,
  # `p.id in subquery(from …)`. `Mutare.Ecto.Fragment` recognizes the wrapper as it walks the
  # condition and delegates the inline `from(...)` argument here; each interior mutant is the whole
  # inner `from` rebuilt with one single-point change, which the caller wraps back into the wrapper
  # (so it becomes another whole-condition branch of the host's existing `^`/`dynamic` weave — no
  # new delivery machinery).
  #
  # **What is mutated is gated by what the wrapper can observe** (`mode`):
  #
  #   * **row-set-changing families — every wrapper (`mode`-agnostic):** the inner
  #     `where`/`having` condition catalog — exactly what the host and `Mutare.Ecto.Dynamic`
  #     compose (`Mutare.Ecto.Host.Catalog.own_catalog/2`: `Fragment`'s operator/literal swaps,
  #     the aggregate swap folded in per node) — and the whole-`from` structural rewrites that
  #     change which rows the subquery returns: filter-clause drops, join-type swaps,
  #     combination-key swaps, and the source binding-reorder, composed from
  #     `Mutare.Ecto.Query`'s producers (`@structural_producers`). A changed row set is observable
  #     through existence, a value set, a scalar, or membership alike.
  #   * **`select` projection — `mode: :value` only** (`all`/`any`/`subquery`/`in`): `Query`'s
  #     `:aggregate`/`:scalar` producers narrowed to the `select`/`select_merge` keys
  #     (`@projection_producers` over `@projection_keys`), where the projected column *is* the
  #     observed value. **Pruned under `mode: :existence`** (`exists`), as equivalent: `EXISTS`
  #     observes only whether the subquery returns a row, and these families rewrite a projected
  #     value without changing how many rows there are — an aggregate swaps for an aggregate
  #     (one row per group either way), an arithmetic swap and a coalesce drop recompute a
  #     column in place. The premise has one known hole, left open: a set-returning function
  #     reached through a `fragment` (Postgres' `generate_series`) makes the row count depend on
  #     the select list, and a swap among its arguments is a live mutant this pruning loses.
  #
  # **Not composed — unimplemented, not equivalent.** Which of these mutants is live turns on the
  # wrapper, on whether the subquery is windowed, and in one case on the engine; no gating for
  # that exists yet, so none is offered (NOTES "Subquery interiors: bounds and ordering are not
  # composed"):
  #
  #   * `limit`/`offset` (`:bound` — the drop is `Query`'s; the ±1 bump is hosted pin-only by
  #     `Mutare.Ecto.Bound` and has no whole-`from` form to compose). Under `exists`,
  #     `offset: k` asks for more than `k` rows, so its drop and both bumps are live; a `limit`
  #     is unobservable only while it stays ≥ 1 — `limit: 1` → `0` makes the predicate
  #     constantly false. Under a value-wrapper a window decides the value set or the scalar —
  #     deterministically given a total `order_by` — and a scalar `subquery` widened past one
  #     row raises on Postgres where SQLite reads the first row.
  #   * `order_by` (`:ordering`, and the `:aggregate`/`:scalar` swaps of its sort keys). Row
  #     order cannot change whether a row exists, nor an unwindowed value set, so it is
  #     unobservable through `exists` and through an unwindowed `all`/`any`/`in`. It is
  #     observable wherever it picks rows: through any windowed value-wrapper (a top-N `in`),
  #     and through a scalar `subquery`, which reads one row — the latest-row idiom
  #     `order_by: [desc: c.at], limit: 1`, and on SQLite (which reads a multi-row scalar's
  #     first row rather than raising) without the `limit` too.
  #   * `distinct`/`group_by`: `Query` has no whole-`from` producer for either (their one
  #     mutation is the pipe-form stage drop, `Mutare.Ecto.ClauseDrop`), so there is nothing to
  #     compose.
  #
  # A pinned `^expr` inside a mutated clause is sub-contracted to core like a top-level pin (see
  # `Mutare.Ecto.Island`): `interior_islands/2` surfaces it from exactly the clauses each `mode`
  # mutates — the `where`/`having` conditions under every mode, the `select` projection under a
  # value-wrapper only. (An EXISTS select's pin binds a projected value `EXISTS` never reads, so
  # a core mutant there could change only whether evaluating the interior raises.)
  #
  # Only an inline `from(source, clauses)` is recursed. In `exists` position, the equivalent
  # `exists(subquery(from …))` spelling is normalized too, with the `subquery/1` wrapper preserved
  # around each rebuilt mutant. A `subquery(var)`, a scalar `from(Post)`, a piped subquery
  # (`exists(q |> where(…))`), and a *from-source* subquery (`from s in subquery(…)`, routed
  # `:raw` and never walked) all yield nothing.

  alias Mutare.Calls
  alias Mutare.Ecto.{Config, Fragment, Query, Surface, Tag}
  alias Mutare.Ecto.AST.{FromCall, KeywordList}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Catalog, Condition}

  # The `Mutare.Ecto.Query` producers composed into the inner `from`: the ones that change the
  # subquery's **row set** (observable through every wrapper), and — under a value-wrapper only —
  # its `:aggregate`/`:scalar` value swaps narrowed to the projection keys. `Query`'s remaining
  # producers (`:ordering`, `:bound`, and those two over `order_by`) are not composed yet (see
  # the module comment).
  @structural_producers [:filter_drop, :join_type, :combination, :binding_reorder]
  @projection_producers [:aggregate, :scalar]
  @projection_keys [:select, :select_merge]

  @typedoc "The wrapper's observation mode — whether its projected `select` is visible."
  @type mode :: :existence | :value

  # The call heads under which `Ecto.Query.Builder.escape/5` accumulates a subquery: `subquery/1`
  # itself, and the quantifiers, which rewrite their argument — whatever it is, an inline `from`
  # or a variable — into `subquery(arg)`.
  @wrappers [:subquery, :all, :any, :exists]

  @doc """
  Whether Ecto would accumulate a subquery while escaping `condition` — a unary call to one of
  `@wrappers` anywhere outside a `^` pin (a pin's interior is Elixir, never escaped). This asks
  about the wrapper alone, so it is wider than what `interior_mutants/3` recurses: `subquery(q)`
  over a variable counts, as does a wrapper inside an author macro's argument.

  Deliberately an unrestricted traversal rather than a `Mutare.Ecto.Walk` reader: its one
  consumer (`Mutare.Ecto.StaticCondition`) falls back to a delivery that is valid either way, so
  a false positive costs nothing while a false negative fails the query build — the traversal
  that sees more is the safe one. It reads source, so a subquery an author macro *expands* to
  stays invisible (NOTES "A macro that expands to a subquery in a `having`").
  """
  @spec present?(Macro.t()) :: boolean()
  def present?(condition) do
    {_pruned, found?} =
      Macro.prewalk(condition, false, fn
        # Prune the interior: `prewalk` descends whatever node is returned.
        {:^, _meta, _args}, found? -> {:pin, found?}
        {head, _meta, [_arg]}, _found? when head in @wrappers -> {:wrapper, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  @doc """
  Every single-point interior mutant of an inline subquery `from`, each the **whole inner `from`**
  rebuilt (which the caller wraps back into the wrapper). `[]` unless `node` is an inline
  `from(source, clauses)` (or, in `:existence` mode, `subquery(from(source, clauses))`).
  Returned as `Mutare.Ecto.Tag`s carrying each family's **normal** tag (`:comparison`,
  `:filter_drop`, `:join_type`, …) and the attribution its producer stamped, so an in-place
  delivery (`Mutare.Ecto.Dynamic`) reports at the inner clause it changed while the host's weave
  discards the stamp (see `Mutare.Ecto.Walk`).
  """
  @spec interior_mutants(Macro.t(), Config.t(), mode()) :: [Tag.t()]
  def interior_mutants(node, %Config{} = config, mode) do
    case inline_from(node, mode) do
      {%FromCall{} = from, wrap} ->
        # mutare:ignore[operand_swap] equivalent — three independent mutant lists, consumed as a set
        for tag <-
              structural(from, config) ++
                conditions(from, config) ++ projection(from, config, mode),
            do: Tag.map_node(tag, wrap)

      nil ->
        []
    end
  end

  @doc """
  Every interpolation **island** (`^expr`) inside the subquery's own mutated clauses, as
  `t:Mutare.Ecto.Fragment.island/0` triples whose `rebuild` reconstructs the whole inner `from` —
  composed outward by the caller. `[]` unless `node` is an inline `from(source, clauses)` (or,
  in `:existence` mode, `subquery(from(source, clauses))`). Which clauses' pins are surfaced
  tracks exactly what each `mode` mutates (see the module comment).
  """
  @spec interior_islands(Macro.t(), mode()) :: [Fragment.island()]
  def interior_islands(node, mode) do
    case inline_from(node, mode) do
      {%FromCall{clauses: clauses} = from, wrap} ->
        KeywordList.flat_map(clauses, &island_clause?(&1, mode), fn entry, index ->
          for {root, root_role, rebuild_value} <- island_roots(entry),
              {interior, role, rebuild} <- Fragment.islands(root, root_role) do
            {interior, role, &wrap.(rebuild_clause(from, index, rebuild_value.(rebuild.(&1))))}
          end
        end)

      nil ->
        []
    end
  end

  # The caller normally reaches value-wrapper `subquery(from …)` interiors by ordinary descent:
  # `Fragment`'s walk enters the `from` argument (its `local/3` recurses it here in `:value`
  # mode) and rebuilds the written `subquery/1` call around each interior mutant.
  # EXISTS is different: its argument is a unit predicate, so `Fragment` delegates the direct
  # argument here instead of descending as a condition. Accept the `subquery(from …)` spelling only
  # in that existence-mode path to avoid double-producing the value-wrapper mutants.
  defp inline_from(node, :existence) do
    case from_call(node) do
      {%FromCall{}, _wrap} = found -> found
      nil -> subquery_wrapped_from(node)
    end
  end

  defp inline_from(node, :value), do: from_call(node)

  # The inline `from` itself (`Mutare.Ecto.AST.FromCall.parse/1` — `nil` for a non-`from` call or
  # a `from` whose clauses aren't a keyword list) with an identity wrap.
  defp from_call(node) do
    case FromCall.parse(node) do
      %FromCall{} = from -> {from, fn mutated -> mutated end}
      nil -> nil
    end
  end

  defp subquery_wrapped_from(node) do
    with {:ok, :subquery, [inner | _rest] = args, rebuild} <-
           Calls.resolved_call_to(node, Ecto.Query, :subquery),
         {%FromCall{} = from, _identity} <- from_call(inner) do
      {from, &rebuild.(:subquery, List.replace_at(args, 0, &1))}
    else
      _ -> nil
    end
  end

  # A clause whose pins we sub-contract: the hosted conditions (every mode), plus a value-wrapper's
  # observed `select` projection. Mirrors exactly the clauses `interior_mutants/3` mutates.
  defp island_clause?(key, mode),
    do: Surface.from_clause?(key, :hosted) or (mode == :value and key in @projection_keys)

  # The roots whose pins are surfaced in one such clause: a condition's are the very roots its
  # catalog walks (`catalog_roots/1`), so the two readers keep agreeing about which nodes exist;
  # a projection is no condition position and is read whole. Each root carries the role of a
  # pin standing *as* that root (`t:Mutare.Ecto.Fragment.role/0` — a pin beneath it reads its
  # own position): a pinned projection (`select: ^fields`) is a list of column names, or a map
  # of dynamics — structure the builder writes out, never a parameter.
  defp island_roots(%Entry{key: key, value: value}) do
    if Surface.from_clause?(key, :hosted),
      do: catalog_roots(value),
      else: [{value, :structural, & &1}]
  end

  # The row-set producers, composed straight from `Mutare.Ecto.Query` — attribution included (the
  # outer condition's walk anchors only an *unattributed* tag, so `Query`'s inner-clause stamp
  # survives to an in-place delivery).
  defp structural(from, config), do: Query.mutations_for(from, config, @structural_producers)

  # The hosted-condition catalog (`Mutare.Ecto.Host.Catalog.own_catalog/2`) recursed into each
  # hosted-clause value (`where`/`having`/`or_where`/`or_having`) — through its `catalog_roots/1`
  # — rebuilding the whole inner `from` around each single-point condition mutant. Nesting
  # (`exists` inside the subquery's own `where`) re-enters `Fragment`, which re-recognizes the
  # wrapper. A clause-less source (`from(Post)` — its reorder rode `structural/2`) contributes
  # nothing here.
  defp conditions(%FromCall{clauses: clauses} = from, config) do
    KeywordList.flat_map(clauses, &Surface.from_clause?(&1, :hosted), fn entry, index ->
      for {root, _pin_role, rebuild_value} <- catalog_roots(entry.value),
          tag <- Catalog.own_catalog(root, config),
          do: Tag.map_node(tag, &rebuild_clause(from, index, rebuild_value.(&1)))
    end)
  end

  # What the predicate catalog may walk in one hosted-clause value, by the classification routing
  # and hosting share (`Mutare.Ecto.Host.Condition.shape/1`), each root with the rebuild of the
  # whole value around its replacement. An interior mutant is delivered as the inner `from`
  # rebuilt — never through `Mutare.Ecto.Host.Target`, so with no `dynamic/2` wrap — and so a
  # predicate, of either kind, is its own root. A keyword filter (`where: [score: 5]`) is not the
  # *host's*, but it stays in a filter position, where nothing refuses it, and, the whole outer
  # condition being hosted, core never reaches its pairs. Each pair **value** is therefore a root,
  # SQL data like the right side of the `c.score == 5` it abbreviates. A **key** never is: it
  # names a column, and the catalog would read `score: 5` as a value tuple with two data sides and
  # rename it (`[mutare: 5]` — an unknown-column query, not a mutant).
  #
  # Each root also says what a pin standing *as* it is to the query (`island_roots/1`): a pinned
  # predicate is a whole `:condition`; a pinned pair value (`where: [score: ^min]`) is the
  # `:value` its column is compared with.
  defp catalog_roots(value) do
    case Condition.shape(value) do
      {:predicate, _kind} ->
        [{value, :condition, & &1}]

      {:keyword_filter, pairs} ->
        for {%Entry{value: pair_value}, index} <- Enum.with_index(pairs.entries) do
          {pair_value, :value,
           &(pairs |> KeywordList.put_value(index, &1) |> KeywordList.to_ast())}
        end

      :pairless_list ->
        []
    end
  end

  # The `select`/`select_merge` projection's aggregate/scalar swaps — `Query`'s own
  # `:aggregate`/`:scalar` producers narrowed to the projection keys — only under a value-wrapper,
  # where the projected column is the observed value. `order_by` (the other key those producers
  # walk) is left out with the rest of the ordering mutants (the module comment's "not composed").
  defp projection(from, config, :value),
    do: Query.mutations_for(from, config, @projection_producers, &(&1 in @projection_keys))

  defp projection(_from, _config, :existence), do: []

  # The whole inner `from` with the clause at `index` carrying `value` — `FromCall` keeps the
  # source's written form and the clause list's Sourceror wrapper.
  defp rebuild_clause(from, index, value),
    do: from |> FromCall.replace_clause(index, value) |> FromCall.to_ast()
end
