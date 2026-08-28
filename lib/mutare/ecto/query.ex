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
      family's other half, the `±1` bump of a literal bound, is hosted pin-only instead
      (`Mutare.Ecto.Bound`).
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
      `intersect_all:`↔`except_all:`. "Does any test pin which rows the combination keeps?" The
      pairing, its portability, and the `union` exclusion are the shared
      `Mutare.Ecto.Combination` catalog's.
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
      (`from [a, b] in q, …`), transpose each pair of those bindings (`[a, b]` → `[b, a]`). "Did
      the author bind the sources in the right order?" The list was written at the whole-`from`
      level, so its reorder is delivered here — the rule and its policy are
      `Mutare.Ecto.BindingReorder`'s.

  Each mutation is returned as a `Mutare.Ecto.Tag`: its label is the finer operator/kind a swap
  family names (order/join/aggregate — `nil` for a structural drop), and its attribution
  (`Mutare.Mutator.Mutation.at/2`/`at_drop/1`) names the **inner clause** the rewrite changed,
  so the site is reported there rather than at the whole `from` (see `Mutare.Ecto.Walk` on
  attribution). `config` carries `dialects:` for the join gate. The `from` is read apart and
  rebuilt through `Mutare.Ecto.AST.FromCall`, which keeps the written form (and owns the
  emptied-clause-list rule). A scalar `from/1` (`from(Post)`, no clauses) yields nothing, while
  a source binding list (`from([a, b] in query)`) can still reorder.
  """

  alias Mutare.Ecto.{Combination, Config, Surface, Tag, ValueCatalog}
  alias Mutare.Ecto.AST.{BindingList, FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Mutator.Mutation

  @behaviour Mutare.Ecto.SubMutator
  @behaviour Mutare.Ecto.Vocabulary

  # JoinType flip tables (the direction policy is the moduledoc's; history in NOTES "JoinType:
  # narrowing only, no introducing swaps"). The gate is about the **target** kind's portability:
  # `left_join`↔`right_join` and `full_join`→`right_join` need `RIGHT JOIN` (`@right_join_dialects`
  # — SQLite lacks it); `left_join`→`inner_join` and `full_join`→`left_join` need no gate.
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
  # Receives the Dispatcher-normalized call (`Mutare.Ecto.SubMutator`). `FromCall.parse/1` reads
  # the `from` apart; one whose clauses aren't a keyword list (`from(p in Post, ^clauses)`)
  # yields nothing.
  def mutations(%QueryCall{} = call, context) do
    case FromCall.parse(call) do
      %FromCall{} = from -> mutations_for(from, Config.from_context(context))
      nil -> []
    end
  end

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
  The whole-`from` mutations for `from` under an already-resolved `%Config{}` — the body
  `mutations/2` delegates to — restricted to `producers` (default: every producer, in
  `mutations/2`'s order) over the clauses whose key `clause?` admits (default: every clause;
  `:binding_reorder` rewrites the source, not a clause, so the predicate never reaches it).

  Exposed so `Mutare.Ecto.Subquery` can **compose** exactly the producers a subquery wrapper
  observes into an inner `from` (where it holds the parsed `FromCall` and config, not a full
  callback context): the row-set producers under every wrapper, and the `select` projection's
  `:aggregate`/`:scalar` swaps under a value-wrapper only — rather than running all eight and
  filtering what it never wanted. An unknown producer is a programming error and fails loudly.
  """
  @spec mutations_for(FromCall.t(), Config.t(), [producer()], (atom() -> boolean())) ::
          [Mutare.Ecto.SubMutator.tagged()]
  def mutations_for(
        %FromCall{} = from,
        %Config{} = config,
        producers \\ @producers,
        clause? \\ fn _key -> true end
      ),
      do: Enum.flat_map(producers, &produce(&1, from, config, clause?))

  # One producer over the parsed `from` — the table `mutations_for/4` folds its `producers`
  # through. Each clause-walking producer admits a clause only when both its own `Surface`
  # capability/drop-family test and the caller's `clause?` hold.
  defp produce(:filter_drop, from, _config, clause?), do: drops(from, :filter_drop, clause?)

  defp produce(:bound, from, _config, clause?), do: drops(from, :bound, clause?)

  defp produce(:ordering, from, _config, clause?), do: value_swaps(from, :ordering, clause?)

  defp produce(:join_type, from, config, clause?), do: join_swaps(from, config, clause?)

  defp produce(:combination, from, _config, clause?), do: combination_swaps(from, clause?)

  defp produce(:aggregate, from, _config, clause?), do: value_swaps(from, :aggregate, clause?)

  defp produce(:scalar, from, _config, clause?), do: value_swaps(from, :scalar, clause?)

  defp produce(:binding_reorder, from, _config, _clause?), do: binding_reorders(from)

  # Whole-`from` binding-reorder of a source binding list (`from [a, b] in q, …` → `[b, a] in q`),
  # rewriting only the source declaration — the in-place rule and its policy are
  # `Mutare.Ecto.BindingReorder`'s. A scalar source (`u in User`) declares no list, so it never
  # reorders.
  defp binding_reorders(%FromCall{source: source} = from) do
    with {:in, meta, [lhs, rhs]} <- source,
         %BindingList{} = list <- BindingList.parse(lhs) do
      for swapped <- BindingList.transpositions(list) do
        swapped_source = {:in, meta, [swapped, rhs]}

        Tag.new(
          :binding_reorder,
          from |> FromCall.replace_source(swapped_source) |> FromCall.to_ast(),
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
  defp drops(%FromCall{clauses: clauses} = from, family, clause?) do
    admit? = &(Surface.from_drop_family(&1) == family and clause?.(&1))

    KeywordList.flat_map(clauses, admit?, fn entry, index ->
      dropped = dropped_indices(clauses, entry, index)

      [
        Tag.new(
          family,
          from |> FromCall.delete_clauses(dropped) |> FromCall.to_ast(),
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
  defp dropped_indices(%KeywordList{entries: entries}, %Entry{key: :limit}, index) do
    case Enum.at(entries, index + 1) do
      %Entry{key: :with_ties} -> [index, index + 1]
      _other -> [index]
    end
  end

  defp dropped_indices(_clauses, _entry, index), do: [index]

  # Swap each join clause's *kind* by rewriting its key (`left_join`→`inner_join`,
  # `full_join`→`left_join`/`right_join`, and `left_join`↔`right_join` under a `RIGHT`-capable
  # dialect), keeping the join's value (`c in assoc(p, :x)`). `join`/`inner_join` are never a
  # flip source, so they never match here. One mutant per enabled target.
  defp join_swaps(from, config, clause?) do
    flips = join_flips(config)

    key_swaps(from, :join_type, clause?, &Map.get(flips, &1, []), &join_label/1)
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
  defp combination_swaps(from, clause?) do
    key_swaps(from, :combination, clause?, &List.wrap(Combination.swap(&1)), &Combination.label/1)
  end

  # Swap a clause's *key* to each target `targets.(key)` yields, keeping its value — the shared
  # delivery for JoinType and Combination. Both filter on and tag with the same `family` atom; each
  # names its own `label.(key)` and attributes the change at the key node. One mutant per target.
  defp key_swaps(%FromCall{clauses: clauses} = from, family, clause?, targets, label) do
    admit? = &(Surface.from_clause?(&1, family) and clause?.(&1))

    KeywordList.flat_map(clauses, admit?, fn entry, index ->
      %Entry{key: key, key_node: key_node} = entry

      for to <- targets.(key) do
        Tag.new(
          family,
          from |> FromCall.rekey_clause(index, to) |> FromCall.to_ast(),
          label.(key),
          Mutation.at(key_node, Mutare.AST.keyword_key(to))
        )
      end
    end)
  end

  # Mutate each clause value the `capability` selects through the shared value dispatch
  # (`Mutare.Ecto.ValueCatalog`, in the position the clause key's capabilities declare) — one
  # mutant per tag, rebuilt into the whole `from`. A walk-based catalog stamps node-level
  # attribution itself (kept); one that doesn't (`Ordering.flips/1`, which replaces a whole
  # entry) falls back to the clause value. A `where`/`having` value is never served here — its
  # condition is hosted (`Mutare.Ecto.Host.Catalog`).
  defp value_swaps(%FromCall{clauses: clauses} = from, capability, clause?) do
    admit? = &(Surface.from_clause?(&1, capability) and clause?.(&1))

    KeywordList.flat_map(clauses, admit?, fn entry, index ->
      position = entry.key |> Surface.from_capabilities() |> ValueCatalog.position()

      for %Tag{node: mutated} = tag <- ValueCatalog.mutants(capability, entry.value, position) do
        %{
          tag
          | node: from |> FromCall.replace_clause(index, mutated) |> FromCall.to_ast(),
            attribution: tag.attribution || Mutation.at(entry.value, mutated)
        }
      end
    end)
  end
end
