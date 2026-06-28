defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition. Delivery concerns
  # (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`.

  alias Mutare.Ecto.{Aggregate, Config, Fragment}

  @doc """
  The configured logical mutants for a condition.

  `reorder_names` are the positional binding names eligible for a binding-reorder — only those the
  author wrote as an explicit `[…]` list (never synthesized from `in`-declarations/joins), supplied
  by the host per call shape.
  """
  @spec mutants(Macro.t(), [atom()], Config.t()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, reorder_names, config) do
    reorders = Fragment.binding_reorders(condition, reorder_names)
    aggregates = Aggregate.swaps(condition)

    for tag <- Fragment.mutants(condition, config) ++ reorders ++ aggregates,
        {family, node, finer} = Config.split_tag(tag),
        Config.family_enabled?(config, family),
        do: Config.enrich(family, node, finer)
  end
end
