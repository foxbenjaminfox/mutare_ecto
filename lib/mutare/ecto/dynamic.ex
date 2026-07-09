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
  `Mutare.Ecto.BindingReorder`'s, exactly as for `where`/`having`). A pin's interior — whether
  *nested* (`dynamic([p], p.x > ^(min + 1))`) or the *whole* body
  (`dynamic([p], ^(if params.sort, do: a, else: b))`) — is never this catalog's: it is ordinary
  Elixir, **sub-contracted to generation over the run's full spec set**, exactly as the host
  sub-contracts a hosted condition's islands. `dynamic` is a registered macro, so core threads
  the run's enabled specs into the whole-call offer as `context.mutators`, and the shared seam
  (`Mutare.Ecto.Host.Catalog.subcontracted/3`) relays each interior rebuild as a
  `Mutare.Mutator.Mutation` with `producer:` set — the Site (and `# mutare:ignore` vocabulary)
  belongs to the producing family, while delivery stays this module's whole-call rewrite
  through the ordinary in-place selector. The full set includes this plugin itself, so a
  further `dynamic(...)` literal buried inside the pin is offered back to **this module** —
  its SQL mutates once, under SQL semantics, recursing one pin level at a time. (A bare
  `^other` body contributes nothing of its own — a variable is mutated nowhere by core — so it
  degrades to no mutants without a special case.)
  """

  alias Mutare.Ecto.{Config, Tag}
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Ecto.Host.{Bindings, Catalog}

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Every single-point in-fragment mutant of a free-standing `dynamic/1,2` call, each the **whole
  call** rebuilt with one condition position swapped — the plugin's own catalog mutants as
  `Mutare.Ecto.Tag`s, the sub-contracted island mutants as producer-attributed
  `Mutare.Mutator.Mutation`s (passed through `Mutare.Ecto.mutate/2` untouched) — or `[]` when
  there is nothing to mutate (a body with no condition, or a top-level-pin body).

  The condition is located by `Mutare.Ecto.Host.Bindings.hosted_condition/1`, which resolves both
  shapes exactly as it does for a standalone `where`: the binding form (`dynamic([p], p.x > 1)` —
  the condition one slot past the written list) and the binding-less form
  (`dynamic(as(:t).x > 1)` — the trailing argument).
  """
  @spec mutations(QueryCall.t(), map()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
  @impl Mutare.Ecto.SubMutator
  # `Mutare.Ecto.Dispatcher` only reaches here once it has already classified the call as the
  # `:dynamic` macro kind, and `Mutare.Ecto.Surface` registers that kind on exactly the `:dynamic`
  # name — so `call.name` is always `:dynamic` by the time this runs.
  def mutations(%QueryCall{name: :dynamic, args: args} = call, context) do
    config = Config.from_context(context)

    case Bindings.hosted_condition(args) do
      {_bindings, condition, index} ->
        # The shared in-fragment catalogs, exactly the pair the hosted path composes
        # (`Mutare.Ecto.Host.Catalog.own_catalog/2`) — returned as raw tags: `Mutare.Ecto.mutate/2`
        # wraps every dispatched tag (`Config.tagged/1`) and core's finalize pass applies the
        # `families:` filter and the equivalence note. For a top-level-pin body the catalog is empty
        # (a `^` has no SQL swap); the sub-contract below carries its interior to core.
        own =
          for tag <- Catalog.own_catalog(condition, config),
              do: Tag.map_node(tag, &QueryCall.replace_arg(call, index, &1))

        # mutare:ignore[operand_swap] equivalent — two independent mutant lists, consumed as a set
        own ++ subcontracted(condition, call, index, context)

      nil ->
        []
    end
  end

  # The island sub-contract, through the same seam the host uses
  # (`Mutare.Ecto.Host.Catalog.subcontracted/3`) — only delivery differs: each interior rebuild
  # is wrapped back into the **whole call** (the free-standing `dynamic`'s in-place shape) rather
  # than relayed as a bare condition for a weave to carry.
  defp subcontracted(condition, call, index, context),
    do: Catalog.subcontracted(condition, context, &QueryCall.replace_arg(call, index, &1))
end
