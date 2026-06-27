defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition. Delivery concerns
  # (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`.

  alias Mutare.Ecto.{Aggregate, Config, Fragment}
  alias Mutare.Ecto.Host.Bindings

  @doc "The configured logical mutants for a condition and its dynamic binding declarations."
  @spec mutants(Macro.t(), [Macro.t()], Config.t()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, bindings, config) do
    reorders = Fragment.binding_reorders(condition, Bindings.positional_names(bindings))
    aggregates = Aggregate.swaps(condition)

    for {family, node} <- Fragment.mutants(condition, config) ++ reorders ++ aggregates,
        Config.family_enabled?(config, family),
        do: Config.noted(family, node)
  end
end
