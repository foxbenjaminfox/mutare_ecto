defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition — the in-fragment
  # operator/literal swaps (`Mutare.Ecto.Fragment`) and the aggregate swap (`Mutare.Ecto.Aggregate`).
  # Delivery concerns (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`.
  # A binding-reorder is *not* hosted: it swaps a written binding list in place (`Mutare.Ecto.BindingReorder`
  # for the standalone/pipe macros, `Mutare.Ecto.Query` for a `from` source list), never the condition body.

  alias Mutare.Ecto.{Aggregate, Config, Fragment}

  @doc "The configured logical mutants for a hosted condition."
  @spec mutants(Macro.t(), Config.t()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, config) do
    aggregates = Aggregate.swaps(condition)

    for tag <- Fragment.mutants(condition, config) ++ aggregates,
        {family, node, finer} = Config.split_tag(tag),
        Config.family_enabled?(config, family),
        do: Config.enrich(family, node, finer)
  end
end
