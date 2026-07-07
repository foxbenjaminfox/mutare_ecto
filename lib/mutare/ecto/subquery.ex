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
  #     `where`/`having` operator/literal swaps (`Mutare.Ecto.Fragment`), aggregate swaps
  #     (`Mutare.Ecto.Aggregate`), and the whole-`from` structural rewrites that change which rows
  #     the subquery returns — filter-clause drops, join-type swaps, combination-key swaps, and the
  #     source binding-reorder (reused from `Mutare.Ecto.Query`, filtered to
  #     `@structural_families`). A changed row set is observable through existence, a value set, a
  #     scalar, or membership alike.
  #   * **`select` projection — `mode: :value` only** (`all`/`any`/`subquery`/`in`): the
  #     `select`/`select_merge` aggregate/scalar swaps (`Mutare.Ecto.Aggregate`/`Scalar`), where the
  #     projected column *is* the observed value. **Suppressed under `mode: :existence`**
  #     (`exists`): SQL never evaluates an EXISTS subquery's select list for any row on any engine,
  #     so a swap there is *unconditionally* equivalent — the same category as `Fragment`'s
  #     `is_nil`-interior suppression, and dropped for the same reason (`Query.mutations`' own
  #     `:aggregate`/`:arithmetic`/`:coalesce` mutants are filtered out, then re-added here for
  #     `select` only, under `:value`).
  #
  # Deliberately **not** mutated (considered and rejected): the inner `order_by` (inert under
  # `exists` and under set-wrappers; only observable in the narrow `order_by … limit 1` scalar
  # shape), `limit`/`offset` (inert under `exists`, a runtime error under a scalar `subquery`,
  # nondeterministic under `all`/`in` without an order), and `distinct`/`group_by` (inert under
  # `exists`/`in`, invisible to `min`/`max`). None is a clean, deterministic, wrapper-general
  # mutant.
  #
  # A pinned `^expr` inside a mutated clause is **not** this catalog's — its interior is ordinary
  # Elixir, core's to mutate — so `interior_islands/2` surfaces it (via `Fragment.islands/1`) for the
  # caller's core sub-contract, exactly as a top-level condition's pin: from the `where`/`having`
  # conditions under every mode, and from the `select` projection under a value-wrapper (never under
  # `exists`, whose select is unobserved — a pin mutant there would be equivalent).
  #
  # Only an inline `from(source, clauses)` is recursed. A `subquery(var)`, a scalar `from(Post)`, a
  # piped subquery (`exists(q |> where(…))`), and a *from-source* subquery (`from s in subquery(…)`,
  # routed `:skip` and never walked) all yield nothing.

  alias Mutare.Ecto.{Aggregate, Config, Fragment, Query, Scalar, Surface}
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry

  # The whole-`from` families from `Mutare.Ecto.Query` that change the subquery's **row set** — the
  # ones observable through every wrapper. Its projection/ordering/window families
  # (`:aggregate`/`:arithmetic`/`:coalesce` for `select`/`order_by`, `:ordering`/`:ordering_nulls`,
  # `:bound`) are filtered out: `select` is re-added per-wrapper here, and the rest are excluded
  # entirely (see the moduledoc).
  @structural_families [:filter_drop, :join_type, :combination, :binding_reorder]

  @typedoc "The wrapper's observation mode — whether its projected `select` is visible."
  @type mode :: :existence | :value

  @doc """
  Every single-point interior mutant of an inline subquery `from`, each the **whole inner `from`**
  rebuilt (which the caller wraps back into the wrapper). `[]` unless `node` is an inline
  `from(source, clauses)`. Returned as `{family, node, label}` triples — `Fragment`'s internal
  contract — carrying each family's **normal** tag (`:comparison`, `:filter_drop`, `:join_type`, …)
  so `Config.tagged/1`, the `families:` filter, and the equivalence notes apply unchanged.
  """
  @spec interior_mutants(Macro.t(), Config.t() | keyword(), mode()) ::
          [{Config.family(), Macro.t(), Fragment.label() | []}]
  def interior_mutants(node, opts, mode) do
    case QueryCall.parse(node) do
      %QueryCall{name: :from, args: args} = call ->
        config = to_config(opts)
        structural(call, config) ++ clause_mutants(call, args, config, mode)

      _other ->
        []
    end
  end

  @doc """
  Every interpolation **island** (`^expr`) inside the subquery's own mutated clauses, as
  `{interior, rebuild}` pairs whose `rebuild` reconstructs the whole inner `from` — composed outward
  by the caller. `[]` unless `node` is an inline `from(source, clauses)`. Which clauses' pins are
  surfaced tracks exactly what each `mode` mutates: the `where`/`having` conditions under every
  mode, plus the `select`/`select_merge` projection under `:value` (its pins are ordinary Elixir the
  outer comparison evaluates). An EXISTS select is unobserved, so its pins — like its swaps — are
  left alone.
  """
  @spec interior_islands(Macro.t(), mode()) :: [{Macro.t(), (Macro.t() -> Macro.t())}]
  def interior_islands(node, mode) do
    with %QueryCall{name: :from, args: [source, clauses_node]} = call <- QueryCall.parse(node),
         %KeywordList{entries: entries} = clauses <- KeywordList.parse(clauses_node) do
      for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
          island_clause?(key, mode),
          {interior, rebuild} <- Fragment.islands(value) do
        {interior, &rebuild_clause(call, source, clauses, index, rebuild.(&1))}
      end
    else
      _ -> []
    end
  end

  # A clause whose pins we sub-contract: the hosted conditions (every mode), plus a value-wrapper's
  # observed `select` projection. Mirrors exactly the clauses `interior_mutants/3` mutates.
  defp island_clause?(key, mode),
    do: Surface.from_clause?(key, :hosted) or (mode == :value and key in [:select, :select_merge])

  # The row-set structural families: `Query.mutations_for/2` (the config-taking entry) over the
  # inner `from`, filtered to the families every wrapper observes, normalized to `Fragment`'s
  # 3-tuple contract (`Query` returns a bare `{family, node}` for the label-less families).
  defp structural(call, config) do
    call
    |> Query.mutations_for(config)
    |> Enum.filter(fn tuple -> elem(tuple, 0) in @structural_families end)
    |> Enum.map(fn
      {family, node} -> {family, node, []}
      {family, node, label} -> {family, node, label}
    end)
  end

  # The clause-value families: the inner conditions (all modes) plus, under `:value`, the `select`
  # projection. Only an inline `from(source, clauses)` with a keyword clause list has these; a
  # scalar/binding-list-only source (its reorder rode `structural/2`) contributes nothing here.
  defp clause_mutants(call, [source, clauses_node], config, mode) do
    case KeywordList.parse(clauses_node) do
      %KeywordList{} = clauses ->
        conditions(call, source, clauses, config) ++
          select_projection(call, source, clauses, mode)

      nil ->
        []
    end
  end

  defp clause_mutants(_call, _args, _config, _mode), do: []

  # Recurse the hosted condition catalogs into each `where`/`having`/`or_where`/`or_having`
  # condition value (the hosted-clause keys), rebuilding the whole inner `from` around each
  # single-point condition mutant. Nesting (`exists` inside the subquery's own `where`) re-enters
  # `Fragment`, which re-recognizes the wrapper.
  defp conditions(call, source, %KeywordList{entries: entries} = clauses, config) do
    for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
        Surface.from_clause?(key, :hosted),
        {family, mutated, label} <- Fragment.mutants(value, config) ++ Aggregate.swaps(value) do
      {family, rebuild_clause(call, source, clauses, index, mutated), label}
    end
  end

  # The `select`/`select_merge` aggregate/scalar swaps — only under a value-wrapper, where the
  # projected column is the observed value. `order_by` is deliberately excluded (its ordering is
  # inert through every wrapper we host).
  defp select_projection(call, source, %KeywordList{entries: entries} = clauses, :value) do
    for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
        key in [:select, :select_merge],
        {family, swapped, label} <- Aggregate.swaps(value) ++ Scalar.swaps(value) do
      {family, rebuild_clause(call, source, clauses, index, swapped), label}
    end
  end

  defp select_projection(_call, _source, _clauses, :existence), do: []

  # Rebuild the whole inner `from` with the clause at `index` carrying `value`, preserving the
  # source's written form (`QueryCall.rebuild/2`) and the clause list's Sourceror wrapper
  # (`KeywordList.replace_value/3`).
  defp rebuild_clause(call, source, clauses, index, value),
    do: QueryCall.rebuild(call, [source, KeywordList.replace_value(clauses, index, value)])

  # `Fragment` threads its `opts` here; in delivery it is the `init/1`-parsed `%Config{}`, but a
  # direct-unit-test `Fragment.mutants/2` may pass raw keyword options — normalize both so
  # `Query.mutations` and the dialect gates see a struct.
  defp to_config(%Config{} = config), do: config
  defp to_config(opts) when is_list(opts), do: Config.parse!(opts)
end
