defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition:
  #
  #   * the plugin's **own** catalog — the in-fragment operator/predicate/literal swaps of
  #     `Mutare.Ecto.Fragment`, which folds the shared per-node scalar and aggregate catalogs in
  #     (`Mutare.Ecto.Scalar`/`Aggregate`) so the condition is walked once — each tagged with
  #     its family labels (`Mutare.Ecto.Tag.to_mutation/1`); the `families:` filter and equivalence
  #     note are core's job — `Mutare.Ecto.finalize/2` runs on every host-target mutant, and core
  #     drops a target whose mutants all skip;
  #   * the **sub-contracted** mutants of each interpolation island (`^expr`), through the shared
  #     seam `Mutare.Ecto.Island.subcontracted/3` — each relayed with `producer:` set, so the Site
  #     belongs to the producing family while the rebuilds are just more branches of the same
  #     woven `^`/`dynamic` selector.
  #
  # Delivery concerns (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`;
  # the pin-only `:bound` bumps of a literal `limit`/`offset` value are `Mutare.Ecto.Bound`'s.
  # A binding-reorder is *not* hosted: it swaps a written binding list in place (`Mutare.Ecto.BindingReorder`
  # for the standalone/pipe macros, `Mutare.Ecto.Query` for a `from` source list), never the condition body.

  alias Mutare.Ecto.{Config, Fragment, Island, Tag}

  @doc """
  The tagged logical mutants for a hosted condition (own catalogs + island sub-contract).

  A **top-level-pin** condition (`where(q, [u], ^cond)`, a join `on: ^cond`) is handled no
  differently: `own` is empty for a pin (the SQL catalogs never mutate a `^`), and
  `Mutare.Ecto.Island.subcontracted/3` surfaces the pin's whole interior as one island and hands
  it to core — so a pinned *Elixir* condition has its Elixir logic mutated by core, exactly as a
  nested pin's parameter is. The SQL/Elixir boundary is enforced by routing and ownership, not
  by refusing to look at the pin.
  """
  @spec mutants(Macro.t(), Config.t(), Mutare.Mutator.context()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, config, context) do
    # The two halves are independent mutant sets (own SQL-catalog swaps vs. sub-contracted pin
    # interiors); concatenation order only affects which arbitrary branch id each ends up under
    # in the woven `^`/`dynamic` selector, never which mutants are produced or how any one branch
    # behaves — equivalent either way.
    # mutare:ignore[operand_swap] equivalent: concatenation order of two independent mutant sets is not observable
    own(condition, config) ++ Island.subcontracted(condition, context)
  end

  @doc """
  The plugin's own in-fragment catalog for a condition — `Mutare.Ecto.Fragment`'s SQL
  operator/predicate/literal swaps, with the shared scalar and aggregate per-node catalogs folded
  in — as raw `Mutare.Ecto.Tag`s, each anchored at the node it mutates. The single name for
  "what the plugin itself mutates in a hosted condition", shared by the host (`own/2`, which tags
  them via `Tag.to_mutation/1`; the weave discards the anchor structurally), `Mutare.Ecto.Dynamic`
  (which rebuilds each into the whole free-standing `dynamic` call and reports it at the anchor),
  and `Mutare.Ecto.Subquery` (which recurses it into a subquery's own `where`/`having` values,
  rebuilding each into the whole inner `from`, the anchor riding along to whichever delivery
  wraps the subquery). `config` threads to `Fragment` only for its `dialects:` gate.
  """
  @spec own_catalog(Macro.t(), Config.t()) :: [Tag.t()]
  def own_catalog(condition, config), do: Fragment.mutants(condition, config)

  # Pure production: each catalog tag becomes `Mutation.tagged(node, [family | finer])`.
  defp own(condition, config), do: Enum.map(own_catalog(condition, config), &Tag.to_mutation/1)
end
