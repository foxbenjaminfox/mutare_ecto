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
    * **JoinType** — narrow a join's kind by rewriting its clause *key*: `left_join`→`inner_join`,
      and `full_join`→`left_join`/`right_join` (plus `left_join`↔`right_join` sideways). "Does any
      test exercise the orphan row this join kind keeps that a narrower kind would drop?" An outer
      join is written *because* unmatched rows must survive, so seed data built for that reason is
      likely to already hold the orphan that makes the narrower kind disagree — a strong, killable
      mutation. The reverse (`inner_join`/`join`→`left_join`, `*`→`full_join`) is deliberately not
      offered: it widens a join the author picked precisely to *exclude* unmatched rows, and
      absent a reason to test for an orphan that shouldn't matter, the widened query usually
      returns identical rows — an equivalent mutant more often than a killable one. The
      `left_join`↔`right_join` swap and `full_join`→`left_join` are portable (every adapter
      supports `INNER`/`LEFT`); `full_join`→`right_join` and the `RIGHT` leg of `left_join`↔
      `right_join` are **dialect-gated** (`:postgres`/`:mysql` — SQLite lacks `RIGHT JOIN`).
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

  Each mutation is returned as a `Mutare.Ecto.Tag`: its label is the finer operator/kind a swap
  family names (order/join/aggregate — `nil` for a structural drop), and its attribution
  (`Mutare.Mutator.Mutation.at/2`/`at_drop/1`) names the **inner clause** the rewrite
  changed, so core reports the site — line/column and diff — at that clause rather than at the
  whole `from`, making a clause-level `# mutare:ignore` reachable even though the node still
  splices the whole rewritten query. The caller (`Mutare.Ecto.Tag.to_mutation/1`) turns this into a
  tagged `Mutation`, then filters by `families:`/a `# mutare:ignore` qualifier; `opts` carries
  `dialects:` for the join gate. A `from` node is `{:from, meta, [source, clauses]}`
  where `clauses` is a keyword list (in Sourceror form, each key wrapped as
  `{:__block__, [format: :keyword], [atom]}`). A scalar `from/1` (`from(Post)`, no clauses) yields
  nothing, while a source binding list (`from([a, b] in query)`) can still reorder.
  """

  alias Mutare.Ecto.{Aggregate, Combination, Config, Ordering, Scalar, Surface, Tag}
  alias Mutare.Ecto.AST.{BindingList, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Mutator.Mutation

  @behaviour Mutare.Ecto.SubMutator
  @behaviour Mutare.Ecto.Vocabulary

  # JoinType: each join-clause key's kind narrows (or, for left↔right, moves sideways) by
  # rewriting its key. `join`/`inner_join` never appear as a flip *source* — widening an inner
  # join to an outer one is the direction we deliberately don't offer (see the moduledoc). Every
  # flip here only permutes a form already reachable from the ones in the source, so none of them
  # is an *introducing* swap the way a widening `*`→`FULL` used to be; the dialect gates below are
  # purely about whether the **target** kind's SQL is portable:
  #
  #   * `left_join`↔`right_join` and `full_join`→`right_join` need `RIGHT JOIN` —
  #     `@right_join_dialects` (`:postgres`/`:mysql`); SQLite lacks it.
  #   * `left_join`→`inner_join` and `full_join`→`left_join` target universally portable kinds,
  #     so they need no dialect gate at all.
  @portable_join_flips %{left_join: [:inner_join], full_join: [:left_join]}
  @right_join_flips %{
    left_join: [:right_join],
    right_join: [:left_join],
    full_join: [:right_join]
  }
  @right_join_dialects [:postgres, :mysql]

  @doc """
  Whole-`from` mutations for a `from(...)` node as self-tagging `Mutare.Ecto.Tag`s (the label the
  finer operator/kind for a swap family, `nil` for a structural drop; the attribution the inner
  clause the site is reported at), or `[]`.
  """
  @spec mutations(QueryCall.t(), Mutare.Mutator.context()) :: [Mutare.Ecto.SubMutator.tagged()]
  @impl Mutare.Ecto.SubMutator
  # `Mutare.Ecto.Dispatcher` normalizes the call (`Mutare.Ecto.AST.QueryCall.parse/1`) before
  # calling here, so a qualified `Ecto.Query.from(…)` or aliased `Q.from(…)` is rewritten exactly
  # like the bare/imported `from(…)`; `rebuild` re-emits each mutant in the source's written form.
  def mutations(%QueryCall{} = call, context),
    do: mutations_for(call, Config.from_context(context))

  @typedoc """
  One whole-`from` producer, named in `Mutare.Ecto.Surface`'s vocabulary: a `from_drop` family
  walked over the clause list (`:filter_drop`, `:bound`), a `from` capability walked over the
  clauses carrying it (the `:ordering`/`:aggregate`/`:scalar` value swaps, the
  `:join_type`/`:combination` key swaps), or the source-level `:binding_reorder`.
  """
  @type producer ::
          :filter_drop
          | :bound
          | :ordering
          | :join_type
          | :combination
          | :aggregate
          | :scalar
          | :binding_reorder

  # Every producer, in the order `mutations/2` runs them.
  @producers [
    :filter_drop,
    :bound,
    :ordering,
    :join_type,
    :combination,
    :aggregate,
    :scalar,
    :binding_reorder
  ]

  @doc """
  The whole-`from` mutations for `call` under an already-resolved `%Config{}` — the config-taking
  body `mutations/2` delegates to — restricted to `producers` (default: every producer, in
  `mutations/2`'s order) over the clauses whose key `clause?` admits (default: every clause;
  `:binding_reorder` rewrites the source, not a clause, so the predicate never reaches it).

  Exposed so `Mutare.Ecto.Subquery` can **compose** exactly the producers a subquery wrapper
  observes into an inner `from` (where it holds the parsed config, not a full callback context):
  the row-set producers under every wrapper, and the `select` projection's `:aggregate`/`:scalar`
  swaps under a value-wrapper only — rather than running all eight and filtering what it never
  wanted. An unknown producer is a programming error and fails loudly.
  """
  @spec mutations_for(QueryCall.t(), Config.t(), [producer()], (atom() -> boolean())) ::
          [Mutare.Ecto.SubMutator.tagged()]
  def mutations_for(call, config, producers \\ @producers, clause? \\ fn _key -> true end)

  def mutations_for(
        %QueryCall{name: :from, args: [source]} = call,
        %Config{},
        producers,
        _clause?
      ),
      do: if(:binding_reorder in producers, do: binding_reorders(call, source), else: [])

  def mutations_for(
        %QueryCall{name: :from, args: [source, clauses]} = call,
        %Config{} = config,
        producers,
        clause?
      ) do
    case KeywordList.parse(clauses) do
      %KeywordList{} = clauses ->
        Enum.flat_map(producers, &produce(&1, call, source, clauses, config, clause?))

      nil ->
        []
    end
  end

  def mutations_for(%QueryCall{}, %Config{}, _producers, _clause?), do: []

  # One producer over the parsed clause list — the table `mutations_for/4` folds its `producers`
  # through. Each clause-walking producer admits a clause only when both its own `Surface`
  # capability/drop-family test and the caller's `clause?` hold.
  defp produce(:filter_drop, call, source, clauses, _config, clause?),
    do: drops(call, source, clauses, :filter_drop, clause?)

  defp produce(:bound, call, source, clauses, _config, clause?),
    do: drops(call, source, clauses, :bound, clause?)

  defp produce(:ordering, call, source, clauses, _config, clause?),
    do: value_swaps(call, source, clauses, :ordering, clause?, &Ordering.flips(&1.value))

  defp produce(:join_type, call, source, clauses, config, clause?),
    do: join_swaps(call, source, clauses, config, clause?)

  defp produce(:combination, call, source, clauses, _config, clause?),
    do: combination_swaps(call, source, clauses, clause?)

  defp produce(:aggregate, call, source, clauses, _config, clause?),
    do: value_swaps(call, source, clauses, :aggregate, clause?, &Aggregate.swaps(&1.value))

  defp produce(:scalar, call, source, clauses, _config, clause?),
    do: value_swaps(call, source, clauses, :scalar, clause?, &scalar_value_swaps/1)

  defp produce(:binding_reorder, call, source, _clauses, _config, _clause?),
    do: binding_reorders(call, source)

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

        Tag.new(
          :binding_reorder,
          QueryCall.replace_arg(call, 0, swapped_source),
          nil,
          Mutation.at(source, swapped_source)
        )
      end
    else
      _ -> []
    end
  end

  # Remove each clause whose key is in `keys`, keeping the others — so the query still
  # compiles (it reuses the surviving clauses). Used for both the filter drops (where/having,
  # tagged `:filter_drop`) and the bound drops (limit/offset, tagged `:bound`).
  defp drops(call, source, clauses, family, clause?) do
    admit? = &(Surface.from_drop_family(&1) == family and clause?.(&1))

    KeywordList.flat_map(clauses, admit?, fn entry, index ->
      [
        Tag.new(
          family,
          rebuild_from(call, source, drop_clause(clauses, entry, index)),
          nil,
          Mutation.at_drop(entry.value)
        )
      ]
    end)
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

  # Swap each join clause's *kind* by rewriting its key (`left_join`→`inner_join`,
  # `full_join`→`left_join`/`right_join`, and `left_join`↔`right_join` under a `RIGHT`-capable
  # dialect), keeping the join's value (`c in assoc(p, :x)`). `join`/`inner_join` are never a
  # flip source, so they never match here. One mutant per enabled target.
  defp join_swaps(call, source, clauses, config, clause?) do
    flips = join_flips(config)

    key_swaps(call, source, clauses, :join_type, clause?, &Map.get(flips, &1, []), &join_label/1)
  end

  # The `# mutare:ignore` label for a join swap: the **source** join kind without its `_join`
  # suffix, so `# mutare:ignore[ecto:left]` leaves a left join's kind alone. Derived structurally
  # (like `Mutare.Ecto.Combination.label/1`) rather than hand-listed, so a new flip source can't
  # go unmapped — in practice only ever `left_join`/`right_join`/`full_join`, since `join`/
  # `inner_join` are never a flip source.
  defp join_label(key), do: String.replace_suffix(Atom.to_string(key), "_join", "")

  # `Mutare.Ecto.Vocabulary`: each source join kind, under both flip tables (`left_join` sits in
  # both, so it repeats — the assembler dedupes).
  @impl Mutare.Ecto.Vocabulary
  def variant_labels do
    [@portable_join_flips, @right_join_flips]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&join_label/1)
  end

  # The portable (narrowing) flips, plus the RIGHT-capable map when `config` enables a dialect
  # that supports it.
  defp join_flips(config) do
    @portable_join_flips
    |> maybe_merge(@right_join_flips, Config.dialect_enabled?(config, @right_join_dialects))
  end

  defp maybe_merge(flips, _added, false), do: flips
  # mutare:ignore[operand_swap] merge order is irrelevant — targets are consumed as a set
  defp maybe_merge(flips, added, true), do: Map.merge(flips, added, fn _k, a, b -> a ++ b end)

  # Swap each set-operation clause's *kind* by rewriting its key (`intersect:`↔`except:`,
  # `intersect_all:`↔`except_all:`), keeping the clause's value (the `^combined` query) — exactly
  # the join-swap delivery, over the shared `Mutare.Ecto.Combination` catalog. `Combination.swap/1`
  # returns `nil` off its flip table (`List.wrap` then yields no target), so a non-swappable key is
  # simply skipped — though `Surface` only registers `:combination` on the flip-table names anyway.
  defp combination_swaps(call, source, clauses, clause?) do
    key_swaps(
      call,
      source,
      clauses,
      :combination,
      clause?,
      &List.wrap(Combination.swap(&1)),
      &Combination.label/1
    )
  end

  # Swap a clause's *key* to each target `targets.(key)` yields, keeping its value — the shared
  # delivery for JoinType and Combination. Both filter on and tag with the same `family` atom; each
  # names its own `label.(key)` and attributes the change at the key node. One mutant per target.
  defp key_swaps(call, source, clauses, family, clause?, targets, label) do
    admit? = &(Surface.from_clause?(&1, family) and clause?.(&1))

    KeywordList.flat_map(clauses, admit?, fn entry, index ->
      %Entry{key: key, key_node: key_node} = entry

      for to <- targets.(key) do
        Tag.new(
          family,
          rebuild_from(call, source, KeywordList.replace_key(clauses, index, to)),
          label.(key),
          Mutation.at(key_node, Mutare.AST.keyword_key(to))
        )
      end
    end)
  end

  # Mutate each clause value the `capability` selects through the shared `catalog` (which
  # receives the whole `Entry`, so a catalog can read the clause key) — one mutant per
  # `{family, node, label}` the catalog yields for that value, rebuilt into the whole `from` and
  # attributed at the mutated node: a walk-based catalog (`Mutare.Ecto.Walk`, under
  # `Mutare.Ecto.ExpressionWalk`'s rules) stamps
  # node-level attribution itself — kept, so the Site lands on the exact expression — and a
  # catalog that doesn't (`Ordering.flips/1`, which replaces a whole entry) falls back to the
  # clause value. Covers the three value-position families delivered as whole-`from` rewrites,
  # each over a `select`/`select_merge`/`order_by` clause value:
  #
  #   * `:ordering` (`Mutare.Ecto.Ordering.flips/1`) — an `order_by` direction/nulls flip.
  #   * `:aggregate` (`Mutare.Ecto.Aggregate.swaps/1`) — a `sum`↔`avg`/`min`↔`max` swap.
  #   * `:scalar` (`scalar_value_swaps/1` over `Mutare.Ecto.Scalar.swaps/2`) — an arithmetic swap
  #     or coalesce drop, position-aware for the `order_by:` key.
  #
  # A `where`/`having` value with any of these is deliberately *not* here: its condition is hosted
  # (`^`/`dynamic`), so those mutants ride the host (`Mutare.Ecto.Fragment`/`Host.catalog/3`)
  # alongside the operator swaps rather than duplicating the whole `from`.
  defp value_swaps(call, source, clauses, capability, clause?, catalog) do
    admit? = &(Surface.from_clause?(&1, capability) and clause?.(&1))

    KeywordList.flat_map(clauses, admit?, fn entry, index ->
      for %Tag{node: mutated} = tag <- catalog.(entry) do
        %{
          tag
          | node: rebuild_from(call, source, KeywordList.replace_value(clauses, index, mutated)),
            attribution: tag.attribution || Mutation.at(entry.value, mutated)
        }
      end
    end)
  end

  # The scalar walk over one clause value, in the position its key declares: an `order_by:` value
  # (the one `from` key carrying `Surface`'s `:ordering` capability alongside `:scalar`) is a
  # sort key, so its coalesce drops carry the placement-aware label/note (`Mutare.Ecto.Scalar`).
  defp scalar_value_swaps(%Entry{key: key, value: value}),
    do: Scalar.swaps(value, if(Surface.from_clause?(key, :ordering), do: :ordering, else: :value))

  # Rebuild the `from` with the chosen clause replaced/removed via the node's own `rebuild`, so the
  # mutant keeps the source's written form (bare/qualified/aliased) — a minimal, shape-correct diff.
  # A drop that removes the *last* clause collapses to the single-argument `from(source)` rather than
  # a `from(source, [])`: the two are semantically identical, but the empty keyword-args list is both
  # noisier and — nested inside a subquery expression (`exists(from(c, []))`) — unrenderable by the
  # Elixir formatter, so the clean single-arg form is the only safe shape. Only a drop can empty the
  # list; every swap family replaces a clause, keeping it non-empty.
  defp rebuild_from(call, source, {:__block__, _meta, [[]]}),
    do: QueryCall.rebuild(call, [source])

  defp rebuild_from(call, source, []), do: QueryCall.rebuild(call, [source])
  defp rebuild_from(call, source, clauses), do: QueryCall.rebuild(call, [source, clauses])
end
