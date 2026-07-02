defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition:
  #
  #   * the plugin's **own** catalogs — the in-fragment operator/literal swaps
  #     (`Mutare.Ecto.Fragment`) and the aggregate swap (`Mutare.Ecto.Aggregate`), each tagged with
  #     its family labels (`Mutare.Ecto.Config.tagged/1`); the `families:` filter and equivalence
  #     note are core's job — `Mutare.Ecto.finalize/2` runs on every host-target mutant, and core
  #     drops a target whose mutants all skip;
  #   * the **sub-contracted** mutants of each interpolation island (`^expr`) — a pin's interior
  #     is ordinary Elixir evaluated at runtime, exactly core's business, so it is handed to
  #     core's generation (`Mutare.Analyze.expression_mutations/3` over `context.mutators`, the
  #     run's enabled non-host specs) and each rebuild is relayed as a
  #     `Mutare.Mutator.Mutation` with `producer:` set — the Site (and its `# mutare:ignore`
  #     vocabulary) belongs to the producing core family, while **delivery stays host-owned**:
  #     the relayed rebuilds are just more branches of the same woven `^`/`dynamic` selector.
  #
  # Delivery concerns (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`.
  # A binding-reorder is *not* hosted: it swaps a written binding list in place (`Mutare.Ecto.BindingReorder`
  # for the standalone/pipe macros, `Mutare.Ecto.Query` for a `from` source list), never the condition body.

  alias Mutare.Ecto.{Aggregate, Config, Fragment}
  alias Mutare.Mutator.Mutation

  @doc "The tagged logical mutants for a hosted condition (own catalogs + island sub-contract)."
  @spec mutants(Macro.t(), Config.t(), Mutare.Mutator.context()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, config, context) do
    own(condition, config) ++ subcontracted(condition, context)
  end

  # Pure production: each catalog tag becomes `Mutation.tagged(node, [family | finer])` — the
  # `config` threads to `Fragment` only for its `dialects:` gate.
  defp own(condition, config) do
    Enum.map(Fragment.mutants(condition, config) ++ Aggregate.swaps(condition), &Config.tagged/1)
  end

  @doc """
  The island sub-contract: `Fragment.islands/1` finds each pin interior under the catalog's own
  descent rules; core generates the interior's mutants under the user's actual configuration
  (`:as` renames and per-instance opts included — a disabled core family simply produces
  nothing), read from `context.mutators` — the run's enabled non-host specs, which core threads
  into both seams this is called from (`host/2` and the whole-call `mutate/2` offer of a
  registered macro). No family tagging here — and the explicit `producer:` makes core skip the
  plugin's `finalize/2` on both paths: the mutant is a *core* family's, with core's note and
  variant, so the plugin's SQL-family filter and equivalence notes don't apply.

  `deliver` maps each rebuilt condition to the node the caller's delivery path emits: the host
  relays the condition itself (its weave carries it — the default identity), while
  `Mutare.Ecto.Dynamic` rebuilds the whole free-standing `dynamic` call around it (its mutants
  are whole-call rewrites through the ordinary in-place selector).
  """
  @spec subcontracted(Macro.t(), Mutare.Mutator.context(), (Macro.t() -> Macro.t())) ::
          [Mutation.t()]
  def subcontracted(condition, context, deliver \\ & &1) do
    specs = Map.get(context, :mutators, [])

    for {interior, rebuild} <- Fragment.islands(condition),
        {spec, mutated, note, variant} <-
          Mutare.Analyze.expression_mutations(interior, specs, context) do
      Mutation.new(deliver.(rebuild.(mutated)), producer: spec, note: note, variant: variant)
    end
  end
end
