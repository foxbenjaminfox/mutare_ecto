defmodule Mutare.Ecto.Island do
  @moduledoc false
  # The interpolation-island seam: a `^` pin's interior is runtime Elixir, analyzed by
  # core over the run's full mutator spec set. The SQL catalog never mutates it. Computed
  # subquery sources use the same seam (`Mutare.Ecto.Subquery.source_islands/1`).
  #
  # The full spec set preserves each producer's configuration and lets nested Ecto calls
  # participate too. Core lowers inner hosted targets to whole-call rewrites, so hosted
  # selectors never nest (NOTES "Inner `from` inside a pin interior: whole-call rewrites only,
  # no condition swaps — RESOLVED (in core)").
  #
  # `Mutation.map_node/2` preserves attribution and the producer, whose `finalize/2` already
  # ran. Core therefore skips the relaying plugin's funnel (`Mutare.Ecto.Equivalence`). The
  # caller controls delivery: the host rebuilds the condition; `Mutare.Ecto.Dynamic` rebuilds
  # its whole call. A bare variable interior contributes no mutations; a dynamic it names
  # mutates where it is built.
  #
  # Only condition owners collect these islands. Pins in other clause values (a bound,
  # ordering or projection) remain raw and unwalked, so moving an expression from a variable
  # into such a pin changes coverage (NOTES "Pins outside a condition are not sub-contracted").
  # Structural filtering belongs to `Mutare.Ecto.Island.Policy`.

  alias Mutare.Ecto.{Context, Fragment}
  alias Mutare.Ecto.Island.Policy
  alias Mutare.Mutator.Mutation

  @doc """
  Collect producer-attributed mutations of each island, filter through `Island.Policy`,
  and rebuild into `condition`, then through the caller's `deliver` function.

  `root_role` describes a pin that is the whole condition: `:condition` for a filter (Ecto
  can interpret its value as a keyword list), `:value` for a dynamic body (a parameter or
  nested dynamic). Nested pins get their positional roles from `Fragment.islands/2`.
  """
  @spec subcontracted(Macro.t(), Fragment.role(), Context.t(), (Macro.t() -> Macro.t())) ::
          [Mutation.t()]
  def subcontracted(condition, root_role, %Context{mutators: specs, core: core}, deliver \\ & &1) do
    # Core's seam takes its own callback context back, unchanged: it carries the enclosing
    # call's lexical environment, in which core resolves the island before analyzing it (a
    # nested `dynamic` keeps its `:raw` route, an author's `:skip` macro stays opaque). The
    # plugin's own struct never crosses.
    for {interior, role, rebuild} <- Fragment.islands(condition, root_role),
        mutation <- Mutare.Analyze.collect_expression(interior, specs, core),
        Policy.allows?(mutation.producer, role, interior, mutation.node) do
      Mutation.map_node(mutation, &deliver.(rebuild.(&1)))
    end
  end
end
