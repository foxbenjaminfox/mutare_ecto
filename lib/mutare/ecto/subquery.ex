defmodule Mutare.Ecto.Subquery do
  @moduledoc false
  # Inline query traversal, separated from the outer condition's delivery.
  # An inline from is rebuilt statically around one catalog mutation; composed stages are
  # query-building Elixir and use the island seam over the entire stage, terminal clause
  # included. Core lowers their hosted targets to whole-call rewrites. A query inside a raw
  # source binding remains outside this traversal.
  #
  # Observation policy for inline from:
  # * Filters, join kinds, combinations and binding reorders can change the row set in any mode.
  # * Projection swaps are observed in value mode. Under EXISTS they are pruned only where no
  #   projected value can decide whether a row survives (`projection_observed?/1`) and the
  #   mutant keeps the query's aggregation (`changes_aggregation?/2`). A set-returning
  #   projection fragment remains a known limitation of this optimization.
  # * Offsets can change existence. A literal limit's bump does when it crosses zero, and its
  #   drop does unless the limit it uncovers is known to match it in zero-ness
  #   (`limit_drop_observed?/1`). Value wrappers receive all bound drops and nonnegative bumps.
  #   An overridden bound never mutates.
  # * Ordering and its value expressions mutate in windowed value queries (a limit or offset,
  #   written or possibly brought by an opaque source). Elsewhere only an ordering value mutant
  #   that may change whether the query aggregates is kept (`aggregating_ordering/2`).
  #   Unwindowed scalar ordering is still not composed, even on SQLite where it can be live.
  # * General clause drops (including group_by/distinct) remain unimplemented here.
  #
  # Pins are collected from conditions and observable projections, with structural roots for
  # projection descriptions. Under EXISTS, a projection pin that is a query parameter is not
  # collected (`island_observed?/3`). Computed query sources go to core as Elixir, never to SQL
  # catalogs.
  # Composed queries use their ordinary stage coverage, as if constructed in a prior assignment;
  # the inline-from equivalence pruning is not applied across that Elixir boundary.

  alias Mutare.Calls
  alias Mutare.Ecto.{Aggregate, AST, Bound, Config, Fragment, Query, Surface, Tag, Walk}
  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Catalog, Condition}

  # Query producers that can change the row set independently of projected values.
  @structural_producers [:filter_drop, :join_type, :combination, :binding_reorder]
  @projection_producers [:aggregate, :scalar]
  @projection_keys [:select, :select_merge]

  # The set operations that keep or remove a row by comparing projected values.
  @value_comparisons [:except, :except_all, :intersect, :intersect_all]

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
  delivery (`Mutare.Ecto.Dynamic`) and the host's weave both report at the inner clause it
  changed (see `Mutare.Ecto.Walk`).
  """
  @spec interior_mutants(Macro.t(), Config.t(), mode()) :: [Tag.t()]
  def interior_mutants(node, %Config{} = config, mode) do
    case inline_from(node, mode) do
      {%FromCall{} = from, wrap} ->
        # mutare:ignore[operand_swap] equivalent — independent mutant lists, consumed as a set
        for tag <-
              structural(from, config) ++
                conditions(from, config) ++
                projection(from, config, mode) ++
                bounds(from, config, mode) ++ ordering(from, config, mode),
            do: Tag.map_node(tag, wrap)

      nil ->
        []
    end
  end

  @doc """
  Every Elixir **island** (a computed source or `^expr` inside the mutated clauses), as
  `t:Mutare.Ecto.Fragment.island/0` triples whose `rebuild` reconstructs the whole inner query —
  composed outward by the caller. An inline `from(source, clauses)` (or, in `:existence` mode,
  `subquery(from(source, clauses))`) also surfaces its clauses' pins, tracking exactly what
  each `mode` mutates (see the module comment). Other query stages relay their whole call.
  """
  @spec interior_islands(Macro.t(), mode()) :: [Fragment.island()]
  def interior_islands(node, mode) do
    case inline_from(node, mode) do
      {%FromCall{clauses: clauses} = from, wrap} ->
        Enum.map(source_islands(from.call.node), fn {source, role, rebuild} ->
          {source, role, &wrap.(rebuild.(&1))}
        end) ++
          KeywordList.flat_map(
            clauses,
            &island_clause?/1,
            fn entry, index ->
              for {root, root_role, rebuild_value} <- island_roots(entry),
                  {interior, role, rebuild} <- Fragment.islands(root, root_role),
                  island_observed?(entry.key, role, projection_mode(from, mode)) do
                {interior, role,
                 &wrap.(rebuild_clause(from, index, rebuild_value.(rebuild.(&1))))}
              end
            end
          )

      nil ->
        query_islands(node, mode)
    end
  end

  # A composed query is ordinary query-building Elixir. Delegate the complete stage,
  # including its terminal clause, to core; its nested host targets are lowered to whole-call
  # rewrites by the same seam used for queries inside pins. Never recurse SQL as Elixir.
  defp query_islands(node, :existence) do
    case Calls.resolved_call_to(node, Ecto.Query, :subquery) do
      {:ok, :subquery, [inner | rest], rebuild} ->
        for {root, role, splice} <- query_islands(inner, :existence),
            do: {root, role, &rebuild.(:subquery, [splice.(&1) | rest])}

      _ ->
        query_islands(node, :value)
    end
  end

  defp query_islands(node, :value) do
    case QueryCall.parse(node) do
      %QueryCall{name: name} when name != :from -> [{node, :value, & &1}]
      _ -> source_islands(node)
    end
  end

  # A computed source is ordinary Elixir, just like a pin's interior.
  # Keep its producer attribution and suppression by sending it through the same core seam.
  # The source is argument 0 whichever way the stage was written (core hands a pipe stage over
  # as the direct call), and it is read through the resolved routes — user overrides included —
  # rather than by re-running the classifier.
  @doc false
  @spec source_islands(Macro.t()) :: [Fragment.island()]
  def source_islands(node) do
    case QueryCall.parse(node) do
      %QueryCall{args: [source | _]} = call ->
        case Calls.routed_treatments(node) do
          [:expression | _] -> [{source, :value, &QueryCall.replace_arg(call, 0, &1)}]
          _ -> []
        end

      _ ->
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

  # A clause whose pins we sub-contract: the hosted conditions and the projection
  # (`island_observed?/3` decides which projection pins).
  defp island_clause?(key), do: Surface.from_clause?(key, :hosted) or key in @projection_keys

  # A condition's pins are observed in every mode, and so are a projection's where its values
  # are observed. Under EXISTS only a projection pin that is a query parameter (role `:value`,
  # `projection_roots/1`) is withheld: its value changes neither the statement nor whether the
  # query aggregates, only projected values, which EXISTS does not read. (A value that fails to
  # encode or to evaluate is not pursued, as for the plugin's own projection mutants.)
  # Every other projection pin computes projection structure, and nothing short of evaluating
  # it shows whether the aggregation survives. `select: ^(if flag, do: aggregate, else: plain)`
  # picks between two dynamics built elsewhere, and in
  # `select: %{n: sum(r.value)}, select_merge: %{^key => 0}` the key decides whether the merge
  # replaces the aggregate. So all of such a pin's mutants are kept, including the equivalent
  # ones (an arithmetic swap inside a projected dynamic): a core mutant is attributed at the
  # Elixir node it changed, and negating `flag` changes a node with no aggregate in it.
  defp island_observed?(key, role, projection_mode) do
    key not in @projection_keys or projection_mode == :value or role != :value
  end

  # The roots whose pins are surfaced in one such clause, each with the role of a pin standing
  # *as* that root (`t:Mutare.Ecto.Fragment.role/0` — a pin beneath it reads its own position).
  # A condition's roots are the very roots its catalog walks (`catalog_roots/1`), so the two
  # readers keep agreeing about which nodes exist. A projection's are the expressions within
  # its select grammar (`projection_roots/1`).
  defp island_roots(%Entry{key: key, value: value}) do
    if Surface.from_clause?(key, :hosted),
      do: for({root, role, _slot, rebuild} <- catalog_roots(value), do: {root, role, rebuild}),
      else: projection_roots(value)
  end

  # A projection is Ecto's select grammar (`Ecto.Query.Builder.Select.escape/4`) around
  # expressions: maps, map updates, structs, tuples, lists, `merge/2`, and `map/2`/`struct/2`
  # takes. This descends the grammar to its expressions, each with the rebuild of the whole
  # projection. Where a pin fills a grammar position, the position decides what Ecto does
  # with its value:
  #
  #   * the whole clause (`select: ^fields`) is a field list, a dynamic, or a map of dynamics,
  #     expanded at runtime: `:structural`;
  #   * a map key (`%{^key => …}`) names an output field, which a merge may replace:
  #     `:structural`;
  #   * a take's field list (`map(r, ^fields)`) names columns: `:structural`;
  #   * anywhere else (a map value, a tuple or list element) Ecto escapes it as a query
  #     parameter: `:value`.
  defp projection_roots({:^, _meta, [_interior]} = pin), do: [{pin, :structural, & &1}]
  defp projection_roots(projection), do: projection_parts(projection)

  defp projection_parts({:%{}, meta, [{:|, bar_meta, [base, updates]}]}) do
    update = fn base, updates -> {:%{}, meta, [{:|, bar_meta, [base, updates]}]} end

    within(projection_parts(base), &update.(&1, updates)) ++
      within(pair_parts(updates), &update.(base, &1))
  end

  defp projection_parts({:%{}, meta, pairs}), do: within(pair_parts(pairs), &{:%{}, meta, &1})

  defp projection_parts({:%, meta, [name, map]}),
    do: within(projection_parts(map), &{:%, meta, [name, &1]})

  defp projection_parts({:merge, meta, [_left, {kind, _, _}] = operands})
       when kind in [:%{}, :map],
       do: within(element_parts(operands), &{:merge, meta, &1})

  defp projection_parts({tag, meta, [{var, _, context} = source, fields]})
       when tag in [:map, :struct] and is_atom(var) and is_atom(context) do
    case fields do
      {:^, _meta, [_interior]} -> [{fields, :structural, &{tag, meta, [source, &1]}}]
      _written -> []
    end
  end

  defp projection_parts({:{}, meta, elements}),
    do: within(element_parts(elements), &{:{}, meta, &1})

  # Sourceror's wrapper around a written list or 2-tuple.
  defp projection_parts({:__block__, meta, [inner]})
       when is_list(inner) or (is_tuple(inner) and tuple_size(inner) == 2),
       do: within(projection_parts(inner), &{:__block__, meta, [&1]})

  defp projection_parts(elements) when is_list(elements), do: element_parts(elements)

  defp projection_parts({left, right}),
    do: within(element_parts([left, right]), fn [left, right] -> {left, right} end)

  defp projection_parts(expression), do: [{expression, :value, & &1}]

  defp element_parts(elements) do
    for {element, index} <- Enum.with_index(elements),
        {root, role, rebuild} <- projection_parts(element),
        do: {root, role, &List.replace_at(elements, index, rebuild.(&1))}
  end

  # A map's (or a map update's) `key => value` pairs. The map-update form is matched before a
  # map's pairs are read, so every member here is a pair.
  defp pair_parts(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{key, value}, index} ->
      within(
        within(key_parts(key), &{&1, value}) ++ within(projection_parts(value), &{key, &1}),
        &List.replace_at(pairs, index, &1)
      )
    end)
  end

  defp key_parts({:^, _meta, [_interior]} = pin), do: [{pin, :structural, & &1}]
  defp key_parts(key), do: projection_parts(key)

  defp within(parts, wrap),
    do: for({root, role, rebuild} <- parts, do: {root, role, &wrap.(rebuild.(&1))})

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
    KeywordList.flat_map(clauses, &condition_clause?/1, fn entry, index ->
      for {root, _pin_role, slot, rebuild_value} <- catalog_roots(entry.value),
          tag <- Catalog.own_catalog(root, config, slot),
          do: Tag.map_node(tag, &rebuild_clause(from, index, rebuild_value.(&1)))
    end)
  end

  defp condition_clause?(key),
    do: Surface.from_clause?(key, :hosted) and not Surface.bound?(key)

  # Bounds are row-count operations, not fragment literals. Reuse the bound catalog and
  # preserve last-wins occurrences; the static mutant pins its changed value like the host.
  defp bounds(%FromCall{clauses: clauses} = from, config, mode) do
    drops =
      Query.mutations_for(from, config, [:bound], fn key ->
        mode == :value or key == :offset or limit_drop_observed?(from)
      end)

    bumps =
      KeywordList.flat_map(clauses, &Surface.bound?/1, fn entry, index ->
        if FromCall.effective_clause?(from, index) do
          for tag <- Bound.tags(entry.value),
              mode == :value or entry.key == :offset or
                AST.int_value(entry.value) == 0 or AST.int_value(tag.node) == 0 do
            Tag.map_node(tag, &rebuild_clause(from, index, {:^, [], [&1]}))
          end
        else
          []
        end
      end)

    drops ++ bumps
  end

  # Under EXISTS a limit decides only whether it is zero. Only the effective limit drops
  # (`Mutare.Ecto.AST.FromCall.effective_clause?/2`), and the drop uncovers the one before it,
  # or, with none written, whatever limit the source brings. The drop is pruned only when both
  # limits are known and agree in zero-ness. A pinned limit, an opaque source's limit, and a
  # zero limit that the drop would lift all keep it.
  defp limit_drop_observed?(%FromCall{clauses: %{entries: entries}} = from) do
    case entries |> Enum.filter(&(&1.key == :limit)) |> Enum.reverse() do
      [effective | earlier] ->
        uncovered =
          case earlier do
            [previous | _] -> zero_ness(previous.value)
            [] -> if plain_source?(from), do: :nonzero, else: :unknown
          end

        before = zero_ness(effective.value)
        before == :unknown or before != uncovered

      [] ->
        false
    end
  end

  # What EXISTS can observe of a limit: whether it is zero. No limit at all is `:nonzero`.
  defp zero_ness(value) do
    case AST.int_value(value) do
      0 -> :zero
      n when is_integer(n) and n > 0 -> :nonzero
      _unknown -> :unknown
    end
  end

  # A windowed value query observes which rows the ordering picks. EXISTS does not. A source
  # that is itself a query (`plain_source?/1`) may bring the window: Ecto keeps
  # `base = from r in "rows", limit: 1` as the limit of `from r in base, order_by: r.id`.
  defp ordering(%FromCall{clauses: %{entries: entries}} = from, config, :value) do
    if Enum.any?(entries, &Surface.bound?(&1.key)) or not plain_source?(from),
      do: Query.mutations_for(from, config, [:ordering, :aggregate, :scalar], &(&1 == :order_by)),
      else: aggregating_ordering(from, config, :value)
  end

  defp ordering(from, config, :existence), do: aggregating_ordering(from, config, :existence)

  # Without a window an ordering never changes which rows there are, but an aggregate in it can
  # decide whether the query aggregates: Postgres aggregates an ungrouped query by one in
  # `ORDER BY` (one row over empty input), and SQLite rejects one there on a query that does not
  # otherwise aggregate. So either wrapper observes an `order_by` value mutant that may change
  # whether the query holds an aggregate, judged as a projection mutant is
  # (`changes_aggregation?/2`) but over the projection's and the ordering's aggregates together.
  # A direction flip never does.
  #
  # SQLite also gives a column neither grouped nor aggregated the value from the row the query's
  # lone `min`/`max` picks, wherever that aggregate stands (`order_by: min(r.x)` included). So
  # where the query may aggregate and such a column is observed (`picks_bare_row?/2`), any
  # ordering value mutant may change which row it reads, and all are kept.
  defp aggregating_ordering(from, config, mode) do
    tags = Query.mutations_for(from, config, [:aggregate, :scalar], &(&1 == :order_by))

    if picks_bare_row?(from, mode),
      do: tags,
      else: Enum.filter(tags, &changes_ordering_aggregation?(from, &1))
  end

  defp picks_bare_row?(%FromCall{clauses: %{entries: entries}} = from, mode) do
    aggregation(ordered_aggregates(from), grouping(entries)) != :no and
      case mode do
        :value ->
          projection_reads_bare_column?(entries)

        :existence ->
          having_reads_bare_column?(entries) or
            (projection_mode(from, :existence) == :value and
               projection_reads_bare_column?(entries))
      end
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
  #
  # And each root says which call argument it fills (`t:Mutare.Ecto.Walk.slot/0`), because the
  # catalog's grammar guards read the parent. A predicate fills none. A pair value fills the
  # right operand of the `==` Ecto builds from the pair, and Ecto rejects a literal `nil` there
  # just as it does in a written comparison. So `[value: coalesce(nil, r.value)]` gets no
  # `[value: nil]` drop.
  @pair_value_slot {:==, 2, 1}

  defp catalog_roots(value) do
    case Condition.shape(value) do
      {:predicate, _kind} ->
        [{value, :condition, nil, & &1}]

      {:keyword_filter, pairs} ->
        for {%Entry{value: pair_value}, index} <- Enum.with_index(pairs.entries) do
          {pair_value, :value, @pair_value_slot,
           &(pairs |> KeywordList.put_value(index, &1) |> KeywordList.to_ast())}
        end

      :pairless_list ->
        []
    end
  end

  # The `select`/`select_merge` projection's aggregate/scalar swaps — `Query`'s own
  # `:aggregate`/`:scalar` producers narrowed to the projection keys — when the wrapper or the query
  # observes projected values. Ordering is composed separately for windowed value queries.
  defp projection(from, config, :value),
    do: Query.mutations_for(from, config, @projection_producers, &(&1 in @projection_keys))

  defp projection(from, config, :existence) do
    tags = projection(from, config, :value)

    if projection_mode(from, :existence) == :value,
      do: tags,
      else: Enum.filter(tags, &changes_aggregation?(from, &1))
  end

  # A projection mutant can change the row count without changing any projected value: it can
  # change whether the query aggregates. Ungrouped, `select: coalesce(0, sum(r.value))` is one
  # row even over an empty table, while its drop, `select: 0`, is a row per input row, so none.
  #
  # Two facts decide aggregation on every engine: a `group_by`, and an aggregate in the
  # projection. `having` and `order_by` do not. Postgres treats an aggregate or a `HAVING` there
  # as making the query aggregate. SQLite reads only the select list, and it rejects a `HAVING`
  # on a query that does not aggregate. So when the drop removes the projection's only aggregate
  # beside a `having`, the result is one row on Postgres and an error on SQLite. The mutant is
  # not equivalent, so it is kept.
  #
  # The mutant is pruned when its replacement holds the same aggregates as the node it replaces,
  # including the ones a pin or fragment may hide (an arithmetic swap beside `^bump`), unless an
  # author macro around it reads its syntax (`clauses_beneath_opaque_call?/3`), or when
  # the query's aggregation is known and the same before and after (`aggregation/2`). Each side
  # is judged on its effective projection (`projected_aggregates/1`), because a later
  # `select_merge` key replaces an earlier field. A drop that keeps an aggregate in its retained
  # operand (`coalesce(min(r.a), max(r.b))` → `min(r.a)`) still aggregates, even though it
  # holds fewer aggregates.
  defp changes_aggregation?(%FromCall{clauses: %{entries: entries}} = from, %Tag{
         node: node,
         attribution: %{original: original, mutated: mutated}
       }) do
    case FromCall.parse(node) do
      %FromCall{} = mutant ->
        grouping = grouping(entries)
        before = aggregation(projected_aggregates(from), grouping)
        after_mutant = aggregation(projected_aggregates(mutant), grouping)
        windows = named_windows(entries)

        (scoped_aggregates(original, windows) != scoped_aggregates(mutated, windows) or
           clauses_beneath_opaque_call?(entries, @projection_keys, original)) and
          (before == :unknown or before != after_mutant)

      nil ->
        true
    end
  end

  defp changes_aggregation?(_from, _unattributed), do: true

  defp changes_ordering_aggregation?(%FromCall{clauses: %{entries: entries}} = from, %Tag{
         node: node,
         attribution: %{original: original, mutated: mutated}
       }) do
    case FromCall.parse(node) do
      %FromCall{} = mutant ->
        grouping = grouping(entries)
        before = aggregation(ordered_aggregates(from), grouping)
        after_mutant = aggregation(ordered_aggregates(mutant), grouping)
        windows = named_windows(entries)

        (scoped_aggregates(original, windows, :expression) !=
           scoped_aggregates(mutated, windows, :expression) or
           clauses_beneath_opaque_call?(entries, [:order_by], original)) and
          (before == :unknown or before != after_mutant)

      nil ->
        true
    end
  end

  defp changes_ordering_aggregation?(_from, _unattributed), do: true

  # The projection's aggregates and the ordering's, as Postgres counts them.
  defp ordered_aggregates(%FromCall{clauses: %{entries: entries}} = from) do
    windows = named_windows(entries)

    for %Entry{key: :order_by, value: value} <- entries,
        reduce: projected_aggregates(from) do
      {written, hidden} ->
        {more_written, more_hidden} = scoped_aggregates(value, windows, :expression)
        {written + more_written, hidden + more_hidden}
    end
  end

  # Whether the replaced node is an argument, at any depth, of a projection call Ecto expands:
  # the expansion reads the node's syntax (`unwrap_sum(sum(x))` may unwrap a `sum` and keep an
  # `avg`), so equal aggregate counts no longer show an unchanged aggregation. Each call is
  # judged in the grammar Ecto reads it in, as the aggregate count judges it (`merge/2` is the
  # select builder's only at the projection's own level).
  defp clauses_beneath_opaque_call?(entries, keys, original) do
    Enum.any?(entries, fn %Entry{key: key, value: value} ->
      key in keys and beneath_opaque_call?(value, root_grammar(key), original)
    end)
  end

  defp root_grammar(key), do: if(key in @projection_keys, do: :projection, else: :expression)

  defp beneath_opaque_call?(node, grammar, original) do
    cond do
      node == original ->
        false

      Walk.opaque_call?(node, grammar) ->
        contains?(node, &(&1 == original))

      true ->
        node
        |> Walk.structural(grammar, &child_grammar/3)
        |> Enum.any?(fn {child, child_grammar, _splice} ->
          beneath_opaque_call?(child, child_grammar, original)
        end)
    end
  end

  # `{written, hidden}` over the fields that survive the projection clauses, folded in written
  # order the way Ecto merges them (`merges/1`). A literal map's key replaces an earlier field
  # with that key. Any other merge (a source, a tuple, a pin, a map with a computed key)
  # contributes whole. After a merge that could replace any key (anything but a literal map),
  # every earlier contribution may or may not survive, so its aggregates count only as hidden.
  # A whole contribution followed by any merge is in the same position.
  defp projected_aggregates(%FromCall{clauses: %{entries: entries}}) do
    windows = named_windows(entries)

    entries
    |> Enum.filter(&(&1.key in @projection_keys))
    |> Enum.flat_map(&merges(&1.value))
    |> Enum.reduce([], fn value, contributions ->
      case literal_map_fields(value) do
        {:ok, fields} ->
          keys = MapSet.new(fields, &elem(&1, 0))

          kept =
            for contribution <- contributions,
                not replaced?(contribution, keys),
                do: maybe_whole(contribution)

          kept ++ for({key, field} <- fields, do: {{:field, key}, field, :certain})

        :error ->
          Enum.map(contributions, fn {kind, part, _} -> {kind, part, :maybe} end) ++
            [{:whole, value, :certain}]
      end
    end)
    |> Enum.reduce({0, 0}, fn {_kind, part, certainty}, {written, hidden} ->
      {w, h} = scoped_aggregates(part, windows)

      case certainty do
        :certain -> {written + w, hidden + h}
        :maybe -> {written, hidden + w + h}
      end
    end)
  end

  defp replaced?({{:field, key}, _part, _certainty}, keys), do: MapSet.member?(keys, key)
  defp replaced?({:whole, _part, _certainty}, _keys), do: false

  defp maybe_whole({:whole, part, _certainty}), do: {:whole, part, :maybe}
  defp maybe_whole(field), do: field

  # One projection clause as the merges Ecto's subquery planner applies in order: a map update
  # (`%{base | pairs}`) keeps its base's fields except the ones its pairs replace, `merge/2` is
  # its left operand merged with its right, and a struct has its map's fields.
  defp merges({:%{}, meta, [{:|, _bar_meta, [base, pairs]}]}),
    do: merges(base) ++ [{:%{}, meta, pairs}]

  defp merges({:merge, _meta, [left, {kind, _, _} = right]}) when kind in [:%{}, :map],
    do: merges(left) ++ merges(right)

  defp merges({:%, _meta, [_name, map]}), do: merges(map)
  defp merges(projection), do: [projection]

  # A map written with literal keys, as `{key, value}` fields in written order, or `:error` if
  # any member is not such a field.
  defp literal_map_fields({:%{}, _meta, pairs}) do
    Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, fields} ->
      case literal_field(pair) do
        {:ok, field} -> {:cont, {:ok, [field | fields]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      :error -> :error
    end
  end

  defp literal_map_fields(_projection), do: :error

  defp literal_field({key, value}) do
    case Mutare.AST.literal_value(key) do
      {:ok, name} when is_atom(name) or is_binary(name) -> {:ok, {name, value}}
      _computed -> :error
    end
  end

  defp literal_field(_update), do: :error

  # `:yes`, `:no` or `:unknown`: whether a query with this grouping and a projection holding
  # `{written, hidden}` aggregates aggregates.
  defp aggregation(_counts, :grouped), do: :yes
  defp aggregation({written, _hidden}, _grouping) when written > 0, do: :yes
  defp aggregation({0, 0}, :ungrouped), do: :no
  defp aggregation(_counts, _grouping), do: :unknown

  # Whether a `group_by` groups the query. A written `[]` or `nil` renders no grouping columns
  # (Ecto `List.wrap`s the value), and an opaque one may be either, so none of them proves
  # grouping.
  defp grouping(entries) do
    group_bys = for %Entry{key: :group_by, value: value} <- entries, do: value

    cond do
      Enum.any?(group_bys, &(grouping_terms(&1) not in [:unknown, []])) -> :grouped
      group_bys != [] -> :unknown
      true -> :ungrouped
    end
  end

  # A pin, a module attribute or an author macro may evaluate to `[]` or `nil`.
  defp grouping_terms(value) do
    case {AST.unwrap_list(value), Mutare.AST.literal_value(value)} do
      {terms, _literal} when is_list(terms) -> terms
      {nil, {:ok, nil}} -> []
      {nil, _expression} -> if opaque_term?(value), do: :unknown, else: [value]
    end
  end

  # `{written, hidden}`: the Ecto aggregates in `node` that aggregate *this* query, and the
  # nodes that may hide one (a pin, a `fragment`, an author macro, a correlated aggregate). A nested query aggregates
  # itself, so it is not entered. A window's function call (`over/1,2`) aggregates the window,
  # so it is skipped. But its operands and the window's options are evaluated in the query's
  # own scope: `over(sum(sum(r.value)))` and `over(row_number(), order_by: sum(r.value))`
  # each hold one ordinary `sum`. An author macro's arguments are entered only under the walk's
  # own rule.
  #
  # Each position carries the grammar Ecto reads it in (`t:Mutare.Ecto.Walk.grammar/0`): a
  # projection's own select grammar (maps, tuples, lists, `merge/2`) passes the projection's on,
  # and any other call's operands are ordinary expressions, where a select-only name such as
  # `map/2` is a macro Ecto expands.
  #
  # A window named in `over/2` (`over(row_number(), :w)`) is read at its use, from the `windows:`
  # definition (`named_windows/1`), exactly as the same options written inline would be: naming
  # a window does not change its meaning, and SQLite aggregates the query by a named window's
  # aggregate only while the projection uses it.
  defp scoped_aggregates(node, windows, grammar \\ :projection) do
    for {position, grammar, _rebuild} <-
          Walk.positions(node, grammar, &query_scope(&1, &2, windows)),
        reduce: {0, 0} do
      {written, hidden} ->
        cond do
          Aggregate.ecto_aggregate?(position) and correlated?(position) -> {written, hidden + 1}
          Aggregate.ecto_aggregate?(position) -> {written + 1, hidden}
          hides_aggregate?(position, grammar) -> {written, hidden + 1}
          true -> {written, hidden}
        end
    end
  end

  # An aggregate over an enclosing query's columns (`max(parent_as(:outer).x)`) belongs to the
  # enclosing query when it reads none of this one's, so it is counted as possibly hiding one.
  defp correlated?(aggregate), do: contains?(aggregate, &match?({:parent_as, _, [_]}, &1))

  # Only positions are read here, never rebuilt, so a child's splice returns its parent.
  defp query_scope({:over, _meta, [function | options]} = node, grammar, windows) do
    if Walk.window?(node),
      do: window_scope(node, function, window_options(options, windows)),
      else: expression_scope(node, grammar)
  end

  defp query_scope({head, _meta, [_arg]}, _grammar, _windows) when head in @wrappers, do: []

  # An opaque call (`Mutare.Ecto.Walk.opaque_call?/2`) is counted once, as possibly hiding an
  # aggregate, and not entered: what its arguments hold may be discarded by its expansion, so an
  # aggregate there is never a certain one. A `fragment` likewise: its raw SQL may put an
  # argument in another scope (`fragment("? OVER ()", count())` is a window function).
  defp query_scope(node, grammar, _windows), do: expression_scope(node, grammar)

  defp expression_scope(node, grammar) do
    if Walk.opaque_call?(node, grammar) or match?({:fragment, _, args} when is_list(args), node),
      do: [],
      else: Walk.structural(node, grammar, &child_grammar/3)
  end

  # A window's operands and options are ordinary expressions; a function kept whole is read in
  # the window's own grammar.
  defp window_scope(node, function, options) do
    for {operand, grammar} <- window_operands(function) ++ Enum.map(options, &{&1, :expression}),
        do: {operand, grammar, fn _ -> node end}
  end

  # The options a window is read with: written inline, or the definition of the window it
  # names. Ecto accepts only a written keyword list as `windows:`, and pins only an option's
  # value (`w: [order_by: ^order]`), which the count reads as it does any pin. A name without a
  # definition is one Ecto rejects.
  defp window_options([name] = options, windows) do
    case Mutare.AST.literal_value(name) do
      {:ok, atom} when is_atom(atom) and not is_nil(atom) -> List.wrap(Map.get(windows, atom))
      _inline -> options
    end
  end

  defp window_options(options, _windows), do: options

  # The windows a query names, `%{name => definition}`, from its `windows:` clauses. Ecto takes
  # only a written list there, of keyword pairs or explicit tuples (`[{:w, [...]}]`) alike.
  defp named_windows(entries) do
    for %Entry{key: :windows, value: value} <- entries,
        element <- AST.unwrap_list(value) || [],
        {name_node, definition} <- [AST.unwrap_pair(element)],
        name = AST.atom_value(name_node),
        name != nil,
        into: %{},
        do: {name, definition}
  end

  defp child_grammar(parent, _index, :projection),
    do: if(select_grammar?(parent), do: :projection, else: :expression)

  # A window function's own operands (a `fragment`'s, say) are ordinary expressions.
  defp child_grammar(_parent, _index, :window_function), do: :expression
  defp child_grammar(_parent, _index, grammar), do: grammar

  # The forms Ecto's select builder reads itself, passing its own grammar on to their elements.
  defp select_grammar?({form, _meta, _args}) when form in [:%{}, :{}, :%, :|, :__block__],
    do: true

  defp select_grammar?({:merge, _meta, [_left, _right]}), do: true
  defp select_grammar?({_left, _right}), do: true
  defp select_grammar?(list), do: is_list(list)

  # The windowed call's operands: a `filter/2`'s aggregate operands and its condition, or a
  # function's arguments. A `fragment` or an author macro may hide an ordinary aggregate
  # (`over(fragment("sum(sum(?))", r.value))`), and a pin is opaque, so each is kept whole to
  # be counted as possibly hiding one.
  defp window_operands({:filter, _meta, [function, condition]}),
    do: window_operands(function) ++ [{condition, :expression}]

  defp window_operands(function) do
    case function do
      {name, _meta, args} when is_atom(name) and is_list(args) ->
        if window_function_hides?(function),
          do: [{function, :window_function}],
          else: Enum.map(args, &{&1, :expression})

      _opaque ->
        [{function, :window_function}]
    end
  end

  defp hides_aggregate?({head, _meta, [_arg]}, _grammar) when head in @wrappers, do: false
  defp hides_aggregate?({:^, _meta, _args}, _grammar), do: true
  defp hides_aggregate?({:fragment, _meta, args}, _grammar) when is_list(args), do: true
  # The walk skips an argument Ecto can only be expanding (`type(is_nil(x), :integer)`), so its
  # call counts it.
  defp hides_aggregate?({:type, _meta, [_operand, _type]} = node, _grammar),
    do: Walk.expanded_argument?(node, 0)

  defp hides_aggregate?(node, grammar), do: Walk.opaque_call?(node, grammar)

  # A window's function is read in its own grammar (`row_number()` is Ecto's there).
  defp window_function_hides?({:^, _meta, _args}), do: true
  defp window_function_hides?({:fragment, _meta, args}) when is_list(args), do: true
  defp window_function_hides?(function), do: Walk.opaque_call?(function, :window_function)

  defp projection_mode(from, :existence),
    do: if(projection_observed?(from), do: :value, else: :existence)

  defp projection_mode(_from, :value), do: :value

  # EXISTS observes only whether a row survives, and a projected value can decide that in
  # these cases:
  #
  #   * EXCEPT/INTERSECT (ALL included) keep or remove rows by comparing projected values;
  #   * a deduplication (UNION, or DISTINCT on the projection) merges rows by projected value, so
  #     the number it leaves depends on them, and an OFFSET that may be positive turns that
  #     number into existence: `{2, 2} ∪ {2}` leaves one row and `OFFSET 1` none, while the
  #     `{0, 2} ∪ {2}` of an arithmetic mutant leaves two and `OFFSET 1` one;
  #   * a clause other than the projection or the ordering reads a projected value back
  #     through `selected_as/1` (`having: selected_as(:total) > 10`), or may
  #     (`reads_selected_alias?/1`);
  #   * a `having` may read a bare column on SQLite, whose row the aggregates pick
  #     (`having_reads_bare_column?/1`);
  #   * the projection splices a pinned list (`fragment("max(?)", splice(^list))`), whose length
  #     is the SQL call's arity, so a core mutant of the list may turn SQLite's scalar
  #     two-argument `max` into its aggregate, and aggregation decides existence;
  #   * the source is a query whose own clauses are out of view (`plain_source?/1`), and any of
  #     the above may hide in them.
  #
  # Only when none of these holds is the projection pruned.
  defp projection_observed?(%FromCall{clauses: %{entries: entries}} = from) do
    not plain_source?(from) or
      Enum.any?(entries, &(&1.key in @value_comparisons)) or
      (Enum.any?(entries, &deduplicates?/1) and offset_may_skip?(entries)) or
      reads_selected_alias?(entries) or
      groups_by_projection?(entries) or
      having_reads_bare_column?(entries) or
      projection_splices?(entries)
  end

  defp projection_splices?(entries) do
    Enum.any?(entries, fn %Entry{key: key, value: value} ->
      key in @projection_keys and contains?(value, &match?({:splice, _, [_]}, &1))
    end)
  end

  # A grouping term may name a projected column by its position: `group_by: 1` is `GROUP BY 1`,
  # which groups by the first projected expression, so a projection mutant can change the
  # groups. It may also hide such a term (`positional?/1`). The number of groups decides
  # existence only past an offset that may skip one, and what a `having` sees in each group
  # only if there is one.
  defp groups_by_projection?(entries) do
    Enum.any?(entries, &(&1.key == :group_by and positional?(&1.value))) and
      (offset_may_skip?(entries) or Enum.any?(entries, &(&1.key in [:having, :or_having])))
  end

  # Whether a grouping or DISTINCT ON value may hold a positional term: an integer literal at
  # the level of its lists and keyword values, or there what may evaluate to one (a pin, which
  # may hold `dynamic(1)`; a module attribute or an author macro, which Ecto expands), or a
  # `fragment` anywhere (`fragment("1")`).
  defp positional?(value) do
    contains?(value, &match?({:fragment, _, args} when is_list(args), &1)) or
      grammar_term?(value, &(is_integer(AST.int_value(&1)) or opaque_term?(&1)))
  end

  defp opaque_term?({:^, _meta, [_interior]}), do: true
  defp opaque_term?(term), do: Walk.opaque_call?(term)

  # Ecto's escape erases `filter/1` (`group_by: filter(1)` is `GROUP BY 1`).
  defp grammar_term?({:filter, _meta, [expression]}, term?), do: grammar_term?(expression, term?)

  # A list, or a `direction => term` pair in either spelling (`asc: 1`, `{:asc, 1}`).
  defp grammar_term?(value, term?) do
    case {AST.unwrap_list(value), AST.unwrap_pair(value)} do
      {elements, _pair} when is_list(elements) -> Enum.any?(elements, &grammar_term?(&1, term?))
      {nil, {_key, term}} -> grammar_term?(term, term?)
      {nil, nil} -> term?.(value)
    end
  end

  # UNION deduplicates the combined projection. `distinct: true` deduplicates the projection,
  # while `distinct: false` does not, and any other written value is DISTINCT ON its own
  # expressions, which may name a projected column by position (`positional?/1`). A pinned
  # value may be `true`.
  defp deduplicates?(%Entry{key: :union}), do: true

  defp deduplicates?(%Entry{key: :distinct, value: value}) do
    case value do
      {:^, _meta, _args} -> true
      _written -> AST.atom_value(value) == true or positional?(value)
    end
  end

  defp deduplicates?(_entry), do: false

  # The effective offset, unless it is a literal zero.
  defp offset_may_skip?(entries) do
    case entries |> Enum.filter(&(&1.key == :offset)) |> List.last() do
      %Entry{value: value} -> AST.int_value(value) != 0
      nil -> false
    end
  end

  # `selected_as/1` is an ordinary expression, so any clause may read an alias: written, or
  # hidden where a clause admits a `dynamic` (`group_by: ^[dynamic(selected_as(:bucket))]`), in
  # an author macro's expansion, or named by a `fragment`'s raw SQL. The hidden reads matter only
  # if the projection may define an alias: a written `selected_as/2`, a call Ecto may expand into
  # one (`Walk.opaque_call?/2`), a `fragment` whose raw SQL may write one, or a pinned
  # projection, which may be a dynamic that writes one.
  defp reads_selected_alias?(entries) do
    {projections, readers} = Enum.split_with(entries, &(&1.key in @projection_keys))
    readers = Enum.reject(readers, &(&1.key == :order_by))

    Enum.any?(readers, &contains?(&1.value, fn node -> match?({:selected_as, _, [_]}, node) end)) or
      (Enum.any?(projections, &may_define_alias?(&1.value)) and
         Enum.any?(readers, &may_read_alias?/1))
  end

  defp may_define_alias?({:^, _meta, [_interior]}), do: true

  # A `fragment`'s raw SQL may define one too (`fragment("? AS n", r.x + 1)`).
  defp may_define_alias?(projection),
    do:
      contains?(
        projection,
        &(match?({:selected_as, _, [_, _]}, &1) or
            match?({:fragment, _, args} when is_list(args), &1))
      ) or Walk.contains_opaque_call?(projection, :projection)

  # A condition admits a dynamic only as the whole condition; a pin within its expression is a
  # parameter. Elsewhere (`group_by`, `distinct`, `windows`) a dynamic may stand at any level of
  # the clause's lists and keyword values. A `fragment` or an author macro may hide a read
  # anywhere.
  defp may_read_alias?(%Entry{key: key, value: value}) do
    contains?(value, &match?({:fragment, _, args} when is_list(args), &1)) or
      Walk.contains_opaque_call?(value) or
      if Surface.from_clause?(key, :hosted),
        do: Condition.shape(value) == {:predicate, :root_pin},
        else: grammar_pin?(value)
  end

  defp grammar_pin?(value), do: grammar_term?(value, &match?({:^, _, [_]}, &1))

  # SQLite lets a `having` read a column that is neither grouped nor aggregated, and gives it
  # the value from the row the query's lone `min`/`max` picked (from an arbitrary row
  # otherwise). So an aggregate swap can change what such a `having` reads while the query
  # aggregates alike: under `having: r.y == 1`, `min(r.x)` → `max(r.x)` reads another row's
  # `y`. (Postgres rejects the bare column.) Outside its aggregate calls, a `having` may read
  # one through a column that no written `group_by` expression names, or through what may hide
  # one: a pinned condition, a `fragment`, a subquery, an author macro. A keyword filter
  # (`having: [y: 1]`) names its columns by key, and is read as possibly bare.
  defp having_reads_bare_column?(entries) do
    grouped = grouped_expressions(entries)

    Enum.any?(entries, fn %Entry{key: key, value: value} ->
      key in [:having, :or_having] and
        case Condition.shape(value) do
          {:predicate, :root_pin} -> true
          {:predicate, :expression} -> bare_column?(value, grouped)
          # Ecto writes each pair as a comparison on its key's column.
          {:keyword_filter, _pairs} -> true
          # Ecto reads an explicit-tuple list (`[{:name, "Carol"}]`) as keyword pairs too; only
          # an empty list is known to read nothing.
          :pairless_list -> AST.unwrap_list(value) != []
        end
    end)
  end

  # A projection reads a bare column as a `having` does, and also through a whole source
  # (`select: r`, `map(r, [:x])`) or a pin, which may be a dynamic or a field list.
  defp projection_reads_bare_column?(entries) do
    grouped = grouped_expressions(entries)

    Enum.any?(entries, fn %Entry{key: key, value: value} ->
      key in @projection_keys and
        (contains?(value, &match?({:^, _, [_]}, &1)) or bare_column?(value, grouped, true))
    end)
  end

  defp grouped_expressions(entries) do
    for %Entry{key: :group_by, value: value} <- entries,
        expression <- AST.unwrap_list(value) || [value],
        into: MapSet.new(),
        do: without_meta(expression)
  end

  defp bare_column?(value, grouped, whole_sources? \\ false) do
    {_pruned, found?} =
      Macro.prewalk(value, false, fn node, found? ->
        cond do
          Walk.window?(node) -> {:window, found? or window_reads_bare?(node, grouped)}
          Aggregate.ecto_aggregate?(node) -> {:aggregate, found?}
          whole_sources? and binding?(node) -> {node, true}
          aggregate_filter?(node) -> {:aggregate, found?}
          # A column is a leaf: its receiver (`as(:p)` in `as(:p).x`) is a binding, not a call.
          column?(node) -> {:column, found? or not MapSet.member?(grouped, without_meta(node))}
          # What Ecto expands (`type(is_nil(x), :integer)`) may be a bare column, whatever
          # aggregate its arguments seem to hold.
          Walk.expands_argument?(node) -> {:expanded, true}
          hides_column?(node) -> {node, true}
          true -> {node, found?}
        end
      end)

    found?
  end

  # A window runs over the aggregated rows, so its own function aggregates nothing there:
  # `over(sum(r.y))` reads `r.y` as the query's bare column. Its options are read likewise, and
  # a shorthand field (`partition_by: :y`), a named window, or any other form may name one.
  # A call Ecto can only be expanding there (`Walk.expanded_argument?/2`) may read anything.
  defp window_reads_bare?({:over, _meta, [function | window]} = node, grouped) do
    Walk.expanded_argument?(node, 0) or bare_column?(window_inputs(function), grouped) or
      Enum.any?(window, &window_options_bare?(&1, grouped))
  end

  # A window function's arguments; a `filter/2`'s are its aggregate's and its condition. A
  # `fragment` is kept whole, for the bare-column reader counts what its SQL may read.
  defp window_inputs({:filter, _meta, [aggregate, condition]}),
    do: [condition | window_inputs(aggregate)]

  defp window_inputs({:fragment, _meta, args} = fragment) when is_list(args), do: [fragment]

  defp window_inputs({_name, _meta, args}) when is_list(args), do: args
  defp window_inputs(_function), do: []

  defp window_options_bare?(options, grouped) do
    case AST.unwrap_list(options) do
      nil ->
        true

      entries ->
        Enum.any?(entries, fn entry ->
          case AST.unwrap_pair(entry) do
            {_key, value} ->
              grammar_term?(value, &(AST.atom_value(&1) != nil)) or bare_column?(value, grouped)

            nil ->
              true
          end
        end)
    end
  end

  defp binding?({name, _meta, context}), do: is_atom(name) and is_atom(context)
  defp binding?(_node), do: false

  defp aggregate_filter?({:filter, _meta, [aggregate, _condition]}),
    do: Aggregate.ecto_aggregate?(aggregate)

  defp aggregate_filter?(_node), do: false

  defp column?({{:., _, [_source, field]}, _meta, []}) when is_atom(field), do: true
  defp column?({:field, _meta, [_source, _name]}), do: true
  defp column?(_node), do: false

  defp hides_column?({head, _meta, [_arg]}) when head in @wrappers, do: true
  defp hides_column?({:fragment, _meta, args}) when is_list(args), do: true
  defp hides_column?(node), do: Walk.opaque_call?(node)

  defp without_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {form, _meta, args} -> {form, [], args}
        node -> node
      end)

  defp contains?(ast, predicate) do
    {_ast, found?} = Macro.prewalk(ast, false, &{&1, &2 or predicate.(&1)})
    found?
  end

  # Whether the source brings no query clauses of its own: a table name, a schema module, both
  # as a tuple, or a `subquery/1` (whose clauses stay inside it). Any other source (a variable,
  # a function call, a nested `from`) is a query whose limit, offset, distinct and combinations
  # the outer clauses extend or override and this traversal cannot see.
  defp plain_source?(%FromCall{source: source}) do
    case source do
      {:in, _meta, [_binding, queryable]} -> plain_queryable?(queryable)
      queryable -> plain_queryable?(queryable)
    end
  end

  defp plain_queryable?({:__block__, _meta, [value]}), do: plain_queryable?(value)
  defp plain_queryable?(table) when is_binary(table), do: true
  defp plain_queryable?({:__aliases__, _meta, _segments}), do: true
  defp plain_queryable?({:__MODULE__, _meta, context}) when is_atom(context), do: true

  defp plain_queryable?({table, schema}),
    do: plain_queryable?(table) and plain_queryable?(schema)

  defp plain_queryable?(node),
    do:
      match?(
        {:ok, :subquery, _args, _rebuild},
        Calls.resolved_call_to(node, Ecto.Query, :subquery)
      )

  # The whole inner `from` with the clause at `index` carrying `value` — `FromCall` keeps the
  # source's written form and the clause list's Sourceror wrapper.
  defp rebuild_clause(from, index, value),
    do: from |> FromCall.replace_clause(index, value) |> FromCall.to_ast()
end
