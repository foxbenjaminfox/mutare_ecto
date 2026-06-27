defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition. Delivery concerns
  # (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`.

  alias Mutare.Ecto.{Aggregate, Config, Fragment}
  alias Mutare.Ecto.Host.Bindings

  @doc "The configured logical mutants for a condition and its dynamic binding declarations."
  @spec mutants(Macro.t(), [Macro.t()], keyword()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, bindings, opts) do
    reorders =
      for node <- Fragment.binding_reorders(condition, Bindings.positional_names(bindings)),
          do: {:binding_reorder, node}

    aggregates = for node <- Aggregate.swaps(condition), do: {:aggregate, node}

    for {family, node} <- Fragment.mutants(condition, opts) ++ reorders ++ aggregates,
        Config.family_enabled?(opts, family),
        do: Config.noted(family, node)
  end
end
