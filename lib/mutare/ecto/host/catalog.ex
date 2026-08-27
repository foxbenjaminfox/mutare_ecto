defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # The logical mutants of one hosted SQL condition: the plugin's **own** catalog
  # (`Mutare.Ecto.Fragment`, with the shared per-node scalar/aggregate catalogs folded in so the
  # condition is walked once) plus the mutants `Mutare.Ecto.Island` sub-contracts for each `^` pin
  # interior — relayed with `producer:` set, so they are just more branches of the same woven
  # `^`/`dynamic` selector. Production only: the `families:` filter and equivalence note are
  # applied by core's `finalize/2` pass (`Mutare.Ecto.Equivalence`), and core drops a target
  # whose mutants all skip.
  #
  # Delivery (`dynamic` wrap, pinning, splicing) lives in `Mutare.Ecto.Host.Target`; the pin-only
  # `:bound` bumps are `Mutare.Ecto.Bound`'s; a binding-reorder is never hosted
  # (`Mutare.Ecto.BindingReorder`).

  alias Mutare.Ecto.{Config, Context, Fragment, Island, Tag}

  @doc """
  The tagged logical mutants for a hosted condition: own catalog + island sub-contract. A
  top-level-pin condition (`where: ^cond`) has an empty own catalog and is carried entirely by
  the sub-contract (`Mutare.Ecto.Island`).
  """
  @spec mutants(Macro.t(), Context.t()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, %Context{config: config} = context) do
    # The two halves are independent mutant sets (own SQL-catalog swaps vs. sub-contracted pin
    # interiors); concatenation order only affects which arbitrary branch id each ends up under
    # in the woven `^`/`dynamic` selector, never which mutants are produced or how any one branch
    # behaves — equivalent either way.
    # mutare:ignore[operand_swap] equivalent: concatenation order of two independent mutant sets is not observable
    own(condition, config) ++ Island.subcontracted(condition, context)
  end

  @doc """
  The plugin's own in-fragment catalog for a condition, as raw `Mutare.Ecto.Tag`s (each anchored
  at the node it mutates — `Mutare.Ecto.Walk`). The single name for "what the plugin itself
  mutates in a hosted condition", shared by the host (`own/2`), `Mutare.Ecto.Dynamic` (whole-call
  rebuilds), and `Mutare.Ecto.Subquery` (recursed into a subquery's own `where`/`having`).
  `config` threads to `Fragment` only for its `dialects:` gate.
  """
  @spec own_catalog(Macro.t(), Config.t()) :: [Tag.t()]
  def own_catalog(condition, config), do: Fragment.mutants(condition, config)

  # Pure production: each catalog tag becomes `Mutation.tagged(node, [family | finer])`.
  defp own(condition, config), do: Enum.map(own_catalog(condition, config), &Tag.to_mutation/1)
end
