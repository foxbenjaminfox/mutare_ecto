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
  #     observed value. **Suppressed under `mode: :existence`** (`exists`): SQL never evaluates an
  #     EXISTS subquery's select list for any row on any engine, so a swap there is
  #     *unconditionally* equivalent — the same category as `Fragment`'s `is_nil`-interior
  #     suppression, and left uncomposed for the same reason.
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
  # Only an inline `from(source, clauses)` is recursed. In `exists` position, the equivalent
  # `exists(subquery(from …))` spelling is normalized too, with the `subquery/1` wrapper preserved
  # around each rebuilt mutant. A `subquery(var)`, a scalar `from(Post)`, a piped subquery
  # (`exists(q |> where(…))`), and a *from-source* subquery (`from s in subquery(…)`, routed
  # `:skip` and never walked) all yield nothing.

  alias Mutare.Calls
  alias Mutare.Ecto.{Config, Fragment, Query, Surface, Tag}
  alias Mutare.Ecto.AST.{FromCall, KeywordList}
  alias Mutare.Ecto.Host.Catalog

  # The `Mutare.Ecto.Query` producers composed into the inner `from`: the ones that change the
  # subquery's **row set** (observable through every wrapper), and — under a value-wrapper only —
  # its `:aggregate`/`:scalar` value swaps narrowed to the projection keys. `Query`'s remaining
  # producers (`:ordering`, `:bound`, and those two over `order_by`) are never composed (see the
  # moduledoc).
  @structural_producers [:filter_drop, :join_type, :combination, :binding_reorder]
  @projection_producers [:aggregate, :scalar]
  @projection_keys [:select, :select_merge]

  @typedoc "The wrapper's observation mode — whether its projected `select` is visible."
  @type mode :: :existence | :value

  @doc """
  Every single-point interior mutant of an inline subquery `from`, each the **whole inner `from`**
  rebuilt (which the caller wraps back into the wrapper). `[]` unless `node` is an inline
  `from(source, clauses)` (or, in `:existence` mode, `subquery(from(source, clauses))`).
  Returned as `Mutare.Ecto.Tag`s — the shared catalog contract — carrying each family's **normal**
  tag (`:comparison`, `:filter_drop`, `:join_type`, …) so `Mutare.Ecto.Tag.to_mutation/1`, the
  `families:` filter, and the equivalence notes apply unchanged. Each tag also keeps the
  attribution its producer stamped (`Query`'s inner-clause attribution, the expression walks' node
  stamp): the host's weave never reads it — a hosted Site is reported at the woven condition —
  while `Mutare.Ecto.Dynamic`'s in-place delivery honours it, so a mutant inside a free-standing
  `dynamic`'s subquery reports at the inner clause it changed, as a top-level `from`'s would.
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
  `{interior, rebuild}` pairs whose `rebuild` reconstructs the whole inner `from` — composed outward
  by the caller. `[]` unless `node` is an inline `from(source, clauses)` (or, in `:existence`
  mode, `subquery(from(source, clauses))`). Which clauses' pins are
  surfaced tracks exactly what each `mode` mutates: the `where`/`having` conditions under every
  mode, plus the `select`/`select_merge` projection under `:value` (its pins are ordinary Elixir the
  outer comparison evaluates). An EXISTS select is unobserved, so its pins — like its swaps — are
  left alone.
  """
  @spec interior_islands(Macro.t(), mode()) :: [{Macro.t(), (Macro.t() -> Macro.t())}]
  def interior_islands(node, mode) do
    case inline_from(node, mode) do
      {%FromCall{clauses: clauses} = from, wrap} ->
        KeywordList.flat_map(clauses, &island_clause?(&1, mode), fn entry, index ->
          for {interior, rebuild} <- Fragment.islands(entry.value) do
            {interior, &wrap.(rebuild_clause(from, index, rebuild.(&1)))}
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

  # The row-set producers, composed straight from `Mutare.Ecto.Query` — attribution included:
  # the outer condition's walk anchors only an *unattributed* tag (`Mutare.Ecto.Walk.mutants/4`),
  # so an in-place delivery reports the drop at the inner clause it removed, while the host's
  # weave discards the stamp structurally (see `interior_mutants/3`).
  defp structural(from, config), do: Query.mutations_for(from, config, @structural_producers)

  # The hosted-condition catalog (`Mutare.Ecto.Host.Catalog.own_catalog/2` — `Fragment` with the
  # aggregate swap folded in, exactly what the host weaves and `Mutare.Ecto.Dynamic` rebuilds)
  # recursed into each `where`/`having`/`or_where`/`or_having` value (the hosted-clause keys),
  # rebuilding the whole inner `from` around each single-point condition mutant. Nesting (`exists`
  # inside the subquery's own `where`) re-enters `Fragment`, which re-recognizes the wrapper. A
  # scalar/binding-list-only source (`from(Post)` — its reorder rode `structural/2`) has an empty
  # clause list, so it contributes nothing here.
  defp conditions(%FromCall{clauses: clauses} = from, config) do
    KeywordList.flat_map(clauses, &Surface.from_clause?(&1, :hosted), fn entry, index ->
      for tag <- Catalog.own_catalog(entry.value, config),
          do: Tag.map_node(tag, &rebuild_clause(from, index, &1))
    end)
  end

  # The `select`/`select_merge` projection's aggregate/scalar swaps — `Query`'s own
  # `:aggregate`/`:scalar` producers narrowed to the projection keys — only under a value-wrapper,
  # where the projected column is the observed value. `order_by` (the other key those producers
  # walk) is deliberately excluded: its ordering is inert through every wrapper we host.
  defp projection(from, config, :value),
    do: Query.mutations_for(from, config, @projection_producers, &(&1 in @projection_keys))

  defp projection(_from, _config, :existence), do: []

  # The whole inner `from` with the clause at `index` carrying `value` — `FromCall` keeps the
  # source's written form and the clause list's Sourceror wrapper.
  defp rebuild_clause(from, index, value),
    do: from |> FromCall.replace_clause(index, value) |> FromCall.to_ast()
end
