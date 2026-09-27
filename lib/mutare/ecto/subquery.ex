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
  #   projected value can decide whether a row survives (`projection_observed?/1`). A
  #   set-returning projection fragment remains a known limitation of this optimization.
  # * Offsets can change existence. A literal limit's bump does when it crosses zero, and its
  #   drop does unless the limit it uncovers is known to match it in zero-ness
  #   (`limit_drop_observed?/1`). Value wrappers receive all bound drops and nonnegative bumps.
  #   An overridden bound never mutates.
  # * Ordering and its value expressions mutate in windowed value queries (limit or offset).
  #   Unwindowed scalar ordering is still not composed, even on SQLite where it can be live.
  # * General clause drops (including group_by/distinct) remain unimplemented here.
  #
  # Pins are collected from conditions and observable projections, with structural roots for
  # projection descriptions. Computed query sources go to core as Elixir, never to SQL catalogs.
  # Composed queries use their ordinary stage coverage, as if constructed in a prior assignment;
  # the inline-from equivalence pruning is not applied across that Elixir boundary.

  alias Mutare.Calls
  alias Mutare.Ecto.{AST, Bound, Config, Fragment, Query, Surface, Tag}
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
            &island_clause?(&1, projection_mode(from, mode)),
            fn entry, index ->
              for {root, root_role, rebuild_value} <- island_roots(entry),
                  {interior, role, rebuild} <- Fragment.islands(root, root_role) do
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
    KeywordList.flat_map(clauses, &condition_clause?/1, fn entry, index ->
      for {root, _pin_role, rebuild_value} <- catalog_roots(entry.value),
          tag <- Catalog.own_catalog(root, config),
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

  # A windowed value query observes which rows the ordering picks. EXISTS does not.
  defp ordering(%FromCall{clauses: %{entries: entries}} = from, config, :value) do
    if Enum.any?(entries, &Surface.bound?(&1.key)),
      do: Query.mutations_for(from, config, [:ordering, :aggregate, :scalar], &(&1 == :order_by)),
      else: []
  end

  defp ordering(_from, _config, :existence), do: []

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
  # `:aggregate`/`:scalar` producers narrowed to the projection keys — when the wrapper or the query
  # observes projected values. Ordering is composed separately for windowed value queries.
  defp projection(from, config, :value),
    do: Query.mutations_for(from, config, @projection_producers, &(&1 in @projection_keys))

  defp projection(from, config, :existence) do
    if projection_mode(from, :existence) == :value,
      do: projection(from, config, :value),
      else: []
  end

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
  #     through `selected_as/1` (`having: selected_as(:total) > 10`);
  #   * the source is a query whose own clauses are out of view (`plain_source?/1`), and any of
  #     the above may hide in them.
  #
  # Only when none of these holds is the projection pruned.
  defp projection_observed?(%FromCall{clauses: %{entries: entries}} = from) do
    not plain_source?(from) or
      Enum.any?(entries, &(&1.key in @value_comparisons)) or
      (Enum.any?(entries, &deduplicates?/1) and offset_may_skip?(entries)) or
      Enum.any?(entries, &reads_selected_alias?/1)
  end

  # UNION deduplicates the combined projection. `distinct: true` deduplicates the projection,
  # while `distinct: false` does not, and any other written value is DISTINCT ON its own
  # expressions. A pinned value may be `true`.
  defp deduplicates?(%Entry{key: :union}), do: true

  defp deduplicates?(%Entry{key: :distinct, value: value}) do
    case value do
      {:^, _meta, _args} -> true
      _written -> AST.atom_value(value) == true
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

  defp reads_selected_alias?(%Entry{key: key, value: value}) do
    key not in [:order_by | @projection_keys] and
      elem(
        Macro.prewalk(value, false, fn
          {:selected_as, _meta, [_name]} = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end),
        1
      )
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
