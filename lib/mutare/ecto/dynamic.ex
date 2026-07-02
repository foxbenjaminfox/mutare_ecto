defmodule Mutare.Ecto.Dynamic do
  @moduledoc """
  In-fragment SQL mutations for a **free-standing** `dynamic/1,2` call — the condition a user
  builds ahead of time and splices later:

      d = dynamic([p], p.views > 100)
      Repo.all(where(query, ^d))

  The condition body is the same SQL fragment a hosted `where`/`having` owns, so the same shared
  catalogs walk it — `Mutare.Ecto.Fragment` (operator/predicate/literal swaps, reasoned in SQL's
  semantics, never core's) and `Mutare.Ecto.Aggregate` (`sum`↔`avg`/`min`↔`max`, for a dynamic
  destined for a `having`). This closes the loop the `where(q, ^d)` splice site deliberately leaves
  open: a top-level `^dynamic` operand is routed raw there because it is *"mutated where it is
  built"* (`Mutare.Ecto.Host.Bindings`) — this module is that build site.

  **Delivery** differs from the hosted path. `dynamic` is registered `:skip`
  (`Mutare.Ecto.Surface.macro_registrations/0`), so core never descends into its DSL arguments —
  but core still offers the *whole call* to `mutate/2`, and a free-standing `dynamic` sits in an
  ordinary expression position (its value is a runtime `%Ecto.Query.DynamicExpr{}`, not a spliced
  query clause). So each mutant is the whole call rebuilt with exactly one point of the condition
  swapped, delivered by Mutare's ordinary in-place selector `case` — the same Bucket-1 delivery as
  the whole-`from` rewrites in `Mutare.Ecto.Query`. No host / `^`-weaving is needed, each selector
  branch invokes the `dynamic` macro independently, and exactly one `DynamicExpr` builds per run.

  The written binding list is re-emitted byte-for-byte (its positional *reorder* is
  `Mutare.Ecto.BindingReorder`'s, exactly as for `where`/`having`). A top-level-pin body
  (`dynamic([p], ^other)`) is left raw: the pin's value is ordinary Elixir bound upstream, core's
  families' to mutate where it is bound. A *nested* pin's interior (`dynamic([p], p.x > ^(min +
  1))`) is likewise never this catalog's — but unlike a hosted `where`/`having` (whose host
  sub-contracts each island to core via `Mutare.Analyze.expression_mutations/3` over
  `context.mutators`), a free-standing `dynamic` is delivered through plain `mutate/2`, which
  core does not hand the run's specs — so an inline island here simply stays unmutated.
  """

  alias Mutare.Ecto.{Aggregate, AST, Config, Fragment}
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Ecto.Host.Bindings

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Every single-point in-fragment mutant of a free-standing `dynamic/1,2` call, each the **whole
  call** rebuilt with one condition position swapped, as `{family, node, label}` tags — or `[]`
  for anything else (a non-`dynamic` call, a body with nothing to mutate, a top-level-pin body).

  The condition is located by `Mutare.Ecto.Host.Bindings.hosted_condition/1`, which resolves both
  shapes exactly as it does for a standalone `where`: the binding form (`dynamic([p], p.x > 1)` —
  the condition one slot past the written list) and the binding-less form
  (`dynamic(as(:t).x > 1)` — the trailing argument).
  """
  @spec mutations(Macro.t() | QueryCall.t(), map()) :: [Mutare.Ecto.SubMutator.tagged()]
  @impl Mutare.Ecto.SubMutator
  def mutations(%QueryCall{name: :dynamic, args: args} = call, context) do
    config = Config.from_context(context)

    with {_bindings, condition, index} <- Bindings.hosted_condition(args),
         false <- AST.top_level_pin?(condition) do
      for {family, mutated, label} <- catalog(condition, config),
          do: {family, QueryCall.replace_arg(call, index, mutated), label}
    else
      _ -> []
    end
  end

  def mutations(%QueryCall{}, _context), do: []

  def mutations(node, context) do
    case QueryCall.parse(node) do
      %QueryCall{} = call -> mutations(call, context)
      nil -> []
    end
  end

  # The shared in-fragment catalogs, exactly the pair the hosted path composes
  # (`Mutare.Ecto.Host.Catalog`) — but returned as raw tags: `Mutare.Ecto.mutate/2` applies the
  # `families:` filter and the equivalence-note enrichment to every dispatched tag itself.
  defp catalog(condition, config),
    do: Fragment.mutants(condition, config) ++ Aggregate.swaps(condition)
end
