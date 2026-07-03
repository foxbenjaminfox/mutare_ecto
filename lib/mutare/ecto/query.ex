defmodule Mutare.Ecto.Query do
  @moduledoc """
  Whole-`from` query mutations — the ones expressible **without** Mutare's foreign-semantics
  DSL host. Each returns a whole mutated `from(...)` node, which
  Mutare's ordinary in-place selector wraps; the localized in-fragment mutations (operator
  swaps inside a `where`, via `^`/`dynamic`) arrive with the host extensions.

    * **Clause drop** — remove one `where`/`having`/`or_where`/`or_having` clause from the
      query. "Is this filter tested?" Reuses the surviving clauses, so it always compiles, and
      works for both the binding form (`from p in Post, where: p.active`) and the bindingless
      form (`from Post, where: [active: true]`) since it operates on the clause list, not the
      clause value.
    * **Order flip** — flip an `order_by` direction (`:asc`↔`:desc`, and the `*_nulls_*`
      variants). "Does any test pin the sort direction?"
    * **Bound (drop)** — drop a `limit`/`offset` clause. "Is the window tested at all?" The
      family's other half, the `±1` bump of a literal bound, is **hosted** (a pin-only
      `limit: ^(case …)` weave — `Mutare.Ecto.Host`), so it no longer duplicates the whole
      `from` per mutant; only the structural drop is a whole-`from` rewrite.
    * **JoinType** — swap a join's kind by rewriting its clause *key*: `join`/`inner_join`
      ↔ `left_join`. "Does any test exercise rows the join's cardinality changes?" An inner
      join drops rows a left join keeps, so the swap is a strong, killable mutation. The
      **portable** pair (every adapter supports `INNER`/`LEFT`) is always offered; the
      `LEFT`↔`RIGHT` pair is **dialect-gated** (`:postgres`/`:mysql` — SQLite lacks `RIGHT`),
      and the `*`→`FULL` swap is gated to `:postgres`/`:sqlite` (MySQL has no `FULL JOIN`).
    * **Combination** — swap a set-operation clause's *key*: `intersect:`↔`except:` and
      `intersect_all:`↔`except_all:` (the shared `Mutare.Ecto.Combination` catalog). "Does any
      test pin which rows the combination keeps?" `A INTERSECT B` and `A EXCEPT B` partition the
      left query's rows, so any left-query row kills the swap. Portable (no dialect gate): it only
      permutes forms of equal adapter support, and `_all`-ness is preserved so the set-op swap is
      never conflated with a distinctness change. `union`/`union_all` have no principled single
      complement, so they only get the orthogonal clause drop.
    * **Aggregate (in `select`/`order_by`)** — swap an aggregate inside a `select`/`select_merge`
      or `order_by` clause value (`sum`↔`avg`, `min`↔`max`), via the shared `Mutare.Ecto.Aggregate`
      walker. "Does any test pin which aggregate the column is reduced/sorted by?" (An aggregate
      inside a `having` is delivered through the host instead — see `Mutare.Ecto.Host`.)
    * **Scalar (in `select`/`order_by`)** — mutate a value-computing form inside a
      `select`/`select_merge` or `order_by` clause value, via the shared `Mutare.Ecto.Scalar`
      catalog: the arithmetic swaps (`+`↔`-`, `*`↔`/`; "does any test pin the computed value?")
      and the coalesce fallback drop (`coalesce(x, d)` → `x`; "does any test exercise the NULL
      row the default is for?"). (The same forms inside a `where`/`having` condition are hosted
      instead, alongside the operator swaps.)
    * **Binding reorder (source list)** — when the source declares a positional binding list
      (`from [a, b] in q, …`), transpose a pair of those bindings (`[a, b]` → `[b, a]`) for every
      pair, whether referenced or not. "Did the author bind the sources in the right order?"
      The author wrote the list at the whole-`from` level, so the swap rewrites only that declaration
      and leaves every clause body untouched — one mutant per pair. The standalone/pipe macros'
      *argument* binding lists reorder in place (`Mutare.Ecto.BindingReorder`); a scalar source and
      synthesized join bindings never reorder.

  Each mutation is returned as `{family, node}` (or `{family, node, label}` for a swap family that
  also names the operator/kind it mutated — order/join/aggregate) so the caller can filter by
  `families:` and a `# mutare:ignore` qualifier; `opts`
  carries `dialects:` for the join gate. A `from` node is `{:from, meta, [source, clauses]}`
  where `clauses` is a keyword list (in Sourceror form, each key wrapped as
  `{:__block__, [format: :keyword], [atom]}`). A scalar `from/1` (`from(Post)`, no clauses) yields
  nothing, while a source binding list (`from([a, b] in query)`) can still reorder.
  """

  alias Mutare.Ecto.{Aggregate, Combination, Config, Ordering, Scalar, Surface}
  alias Mutare.Ecto.AST.{BindingList, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry

  @behaviour Mutare.Ecto.SubMutator

  # JoinType: each join-clause key's kind swaps. `join` is the keyword-form default inner join.
  # The portable pair (`INNER`↔`LEFT`) is always offered; the non-portable pairs are added only
  # under a dialect that supports them:
  #
  #   * `LEFT`↔`RIGHT` — `@right_join_dialects` (`:postgres`/`:mysql`); SQLite lacks `RIGHT JOIN`.
  #   * `*`→`FULL` (and `FULL`→`LEFT`) — `@full_join_dialects` (`:postgres`/`:sqlite` ≥ 3.39);
  #     MySQL has no `FULL JOIN` at any version. This is an *introducing* swap (the source's
  #     `inner`/`left` becomes a `FULL` not written by the user), so it must be dialect-gated —
  #     unlike a swap that only permutes a form already in the source.
  @portable_join_flips %{join: [:left_join], inner_join: [:left_join], left_join: [:inner_join]}
  @right_join_flips %{left_join: [:right_join], right_join: [:left_join]}
  @right_join_dialects [:postgres, :mysql]
  @full_join_flips %{
    join: [:full_join],
    inner_join: [:full_join],
    left_join: [:full_join],
    right_join: [:full_join],
    full_join: [:left_join]
  }
  @full_join_dialects [:postgres, :sqlite]

  @doc """
  Whole-`from` mutations for a `from(...)` node as self-tagging `{family, node}` /
  `{family, node, label}` entries (a swap family — order/join/aggregate — appends the finer
  operator/kind label), or `[]`.
  """
  @spec mutations(Macro.t() | QueryCall.t(), Mutare.Mutator.context()) ::
          [Mutare.Ecto.SubMutator.tagged()]
  @impl Mutare.Ecto.SubMutator
  # Normalize the call (`Mutare.Ecto.AST.QueryCall.parse/1`) so a qualified `Ecto.Query.from(…)` or
  # aliased `Q.from(…)` is rewritten exactly like the bare/imported `from(…)`; `rebuild` re-emits each
  # mutant in the source's written form.
  def mutations(%QueryCall{} = call, context) do
    config = Config.from_context(context)

    case call do
      %QueryCall{name: :from, args: [source]} ->
        binding_reorders(call, source)

      %QueryCall{name: :from, args: [source, clauses]} ->
        case KeywordList.parse(clauses) do
          %KeywordList{} = clauses -> from_mutations(source, clauses, call, config)
          nil -> []
        end

      _ ->
        []
    end
  end

  def mutations(node, context) do
    case QueryCall.parse(node) do
      %QueryCall{} = call -> mutations(call, context)
      nil -> []
    end
  end

  defp from_mutations(source, clauses, call, config) do
    Enum.concat([
      drops(call, source, clauses, :filter_drop),
      drops(call, source, clauses, :bound),
      order_flips(call, source, clauses),
      join_swaps(call, source, clauses, config),
      combination_swaps(call, source, clauses),
      aggregate_swaps(call, source, clauses),
      scalar_swaps(call, source, clauses),
      binding_reorders(call, source)
    ])
  end

  # Whole-`from` binding-reorder: a `from` whose **source** declares a positional binding list
  # (`from [a, b] in q, …`) wrote that list at the whole-`from` level, so its reorder belongs there —
  # swap every pair of reorderable positional bindings, rewriting only the source declaration
  # (`[b, a] in q`) and never a clause body. Usage is deliberately irrelevant: an unused declaration
  # still earns a swap, as it does under core's pattern-swap mutator. A scalar source (`u in User`)
  # declares no list and a join-introduced binding is synthesized, so neither reorders; the
  # standalone/pipe macros' own written lists reorder in `Mutare.Ecto.BindingReorder` instead.
  defp binding_reorders(call, source) do
    with {:in, meta, [lhs, rhs]} <- source,
         %BindingList{} = list <- BindingList.parse(lhs) do
      for swapped <- BindingList.transpositions(list) do
        swapped_source = {:in, meta, [swapped, rhs]}
        {:binding_reorder, QueryCall.replace_arg(call, 0, swapped_source)}
      end
    else
      _ -> []
    end
  end

  # Remove each clause whose key is in `keys`, keeping the others — so the query still
  # compiles (it reuses the surviving clauses). Used for both the filter drops (where/having,
  # tagged `:filter_drop`) and the bound drops (limit/offset, tagged `:bound`).
  defp drops(call, source, %KeywordList{entries: entries} = clauses, family) do
    for {%Entry{} = entry, index} <- Enum.with_index(entries),
        Surface.from_drop_family(entry.key) == family do
      {family, rebuild_from(call, source, drop_clause(clauses, entry, index))}
    end
  end

  # Dropping a `limit:` takes an immediately-following `with_ties:` with it: Ecto validates the
  # adjacency at expansion time ("`with_ties` keyword must immediately follow a limit"), so a
  # dangling `with_ties:` would fail the metamutant *build* — poisoning every mutant in the file —
  # rather than yield a live one. The pair is one syntactic unit (the tie mode qualifies the
  # limit), so removing the limit removes its tie mode as the same single mutant.
  defp drop_clause(%KeywordList{entries: entries} = clauses, %Entry{key: :limit}, index) do
    case Enum.at(entries, index + 1) do
      %Entry{key: :with_ties} -> KeywordList.delete(clauses, [index, index + 1])
      _other -> KeywordList.delete(clauses, index)
    end
  end

  defp drop_clause(clauses, _entry, index), do: KeywordList.delete(clauses, index)

  # Swap each join clause's *kind* by rewriting its key (`join`/`inner_join` ↔ `left_join`, plus
  # `left_join`↔`right_join` under a `RIGHT`-capable dialect and `*`→`full_join` under a
  # `FULL`-capable one), keeping the join's value (`c in assoc(p, :x)`). One mutant per enabled
  # target.
  defp join_swaps(call, source, %KeywordList{entries: entries} = clauses, config) do
    flips = join_flips(config)

    for {%Entry{key: key}, index} <- Enum.with_index(entries),
        Surface.from_clause?(key, :join_type),
        to <- Map.get(flips, key, []) do
      {:join_type, rebuild_from(call, source, KeywordList.replace_key(clauses, index, to)),
       join_label(key)}
    end
  end

  # The `# mutare:ignore` label for a join swap: the **source** join kind, normalized
  # (`inner_join`/`join` → `"inner"`), so `# mutare:ignore[ecto:left]` leaves a left join's kind
  # alone. Derived alongside `variant_labels/0` from the flip tables' keys.
  defp join_label(:join), do: "inner"
  defp join_label(:inner_join), do: "inner"
  defp join_label(:left_join), do: "left"
  defp join_label(:right_join), do: "right"
  defp join_label(:full_join), do: "full"

  @doc false
  # The finer `# mutare:ignore` labels the `:join_type` family can emit — each source join kind,
  # derived from the flip tables so the vocabulary can't drift. Folded into the plugin's variant
  # vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels do
    [@portable_join_flips, @right_join_flips, @full_join_flips]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&join_label/1)
    |> Enum.uniq()
  end

  # The portable flips, plus each dialect-gated map whose dialects the `config` enables (`RIGHT`,
  # `FULL`). Independently gated, so a config can enable one without the other.
  defp join_flips(config) do
    @portable_join_flips
    |> maybe_merge(@right_join_flips, Config.dialect_enabled?(config, @right_join_dialects))
    |> maybe_merge(@full_join_flips, Config.dialect_enabled?(config, @full_join_dialects))
  end

  defp maybe_merge(flips, _added, false), do: flips
  # mutare:ignore[operand_swap] merge order is irrelevant — targets are consumed as a set
  defp maybe_merge(flips, added, true), do: Map.merge(flips, added, fn _k, a, b -> a ++ b end)

  # Swap each set-operation clause's *kind* by rewriting its key (`intersect:`↔`except:`,
  # `intersect_all:`↔`except_all:`), keeping the clause's value (the `^combined` query) — exactly
  # the join-swap delivery, over the shared `Mutare.Ecto.Combination` catalog. The `:combination`
  # capability is only registered on the flip-table names, so `swap/1` is total here.
  defp combination_swaps(call, source, %KeywordList{entries: entries} = clauses) do
    for {%Entry{key: key}, index} <- Enum.with_index(entries),
        Surface.from_clause?(key, :combination),
        to = Combination.swap(key),
        # mutare:ignore[conditional] equivalent — Surface only registers :combination on the 4 names Combination.swap/1's flip table covers, so swap/1 is total here and `to` is never nil
        not is_nil(to) do
      {:combination, rebuild_from(call, source, KeywordList.replace_key(clauses, index, to)),
       Combination.label(key)}
    end
  end

  # Swap each aggregate inside a `select`/`select_merge`/`order_by` clause value — one mutant per
  # aggregate position (`Mutare.Ecto.Aggregate`). A `having` aggregate is deliberately *not* here:
  # its condition is hosted (`^`/`dynamic`), so the swap rides the host alongside the operator swaps
  # (`Mutare.Ecto.Host.catalog/3`) rather than being delivered as a whole-`from` rewrite.
  defp aggregate_swaps(call, source, %KeywordList{entries: entries} = clauses) do
    for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
        Surface.from_clause?(key, :aggregate),
        {family, swapped, label} <- Aggregate.swaps(value) do
      {family, rebuild_from(call, source, KeywordList.replace_value(clauses, index, swapped)),
       label}
    end
  end

  # Mutate each scalar form inside a `select`/`select_merge`/`order_by` clause value — one mutant
  # per position, arithmetic swap or coalesce drop (`Mutare.Ecto.Scalar`). Like the aggregate
  # swap, a `where`/`having` scalar is deliberately *not* here: the condition is hosted, so its
  # mutants ride the host via `Mutare.Ecto.Fragment` (no double-delivery).
  defp scalar_swaps(call, source, %KeywordList{entries: entries} = clauses) do
    for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
        Surface.from_clause?(key, :scalar),
        {family, swapped, label} <- Scalar.swaps(value) do
      {family, rebuild_from(call, source, KeywordList.replace_value(clauses, index, swapped)),
       label}
    end
  end

  # Flip each `order_by` clause's directions, reusing the shared ordering catalog — one mutant
  # per axis per direction key, tagged with its family (`:ordering` direction / `:ordering_nulls`
  # placement; see `Mutare.Ecto.Ordering`).
  defp order_flips(call, source, %KeywordList{entries: entries} = clauses) do
    for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
        Surface.from_clause?(key, :ordering),
        {family, flipped, label} <- Ordering.flips(value) do
      {family, rebuild_from(call, source, KeywordList.replace_value(clauses, index, flipped)),
       label}
    end
  end

  # Rebuild the `from` with the chosen clause replaced/removed via the node's own `rebuild`, so the
  # mutant keeps the source's written form (bare/qualified/aliased) — a minimal, shape-correct diff.
  defp rebuild_from(call, source, clauses), do: QueryCall.rebuild(call, [source, clauses])
end
