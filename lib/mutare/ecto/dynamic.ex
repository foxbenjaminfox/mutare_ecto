defmodule Mutare.Ecto.Dynamic do
  @moduledoc """
  In-fragment SQL mutations for a **free-standing** `dynamic/1,2` call — the condition a user
  builds ahead of time and splices later:

      d = dynamic([p], p.views > 100)
      Repo.all(where(query, ^d))

  The condition body is the same SQL fragment a hosted `where`/`having` owns, so the same shared
  catalog walks it — `Mutare.Ecto.Fragment` (operator/predicate/literal swaps, reasoned in SQL's
  semantics, never core's, with the scalar and aggregate per-node catalogs folded in:
  `sum`↔`avg`/`min`↔`max` for a dynamic destined for a `having`). Each mutant is **reported at
  the mutated expression** (the walk anchors it — `Mutare.Ecto.Walk`), even though what is
  delivered is the whole rebuilt call. This closes the loop the `where(q, ^d)` splice site leaves
  open: a top-level `^d` is hosted there like any other condition (`Mutare.Ecto.Host.Routing`), but
  the SQL catalog stops at the pin and the island sub-contract finds only a bare variable inside,
  which core mutates nowhere (`Mutare.Ecto.Island`) — the splice contributes nothing of its own,
  so the `dynamic` is *mutated where it is built*. This module is that build site.

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
  (`Mutare.Ecto.Island.subcontracted/3`) relays each interior rebuild as a
  `Mutare.Mutator.Mutation` with `producer:` set — the Site (and `# mutare:ignore` vocabulary)
  belongs to the producing family, while delivery stays this module's whole-call rewrite
  through the ordinary in-place selector. The full set includes this plugin itself, so a
  further `dynamic(...)` literal buried inside the pin is offered back to **this module** —
  its SQL mutates once, under SQL semantics, recursing one pin level at a time — and an inner
  `from`/clause macro's hosted conditions come back **lowered** by core's collect (the inner
  call rebuilt around the mutated condition, `^dynamic`-pinned, in place of a weave that
  cannot nest). (A bare `^other` body contributes nothing of its own — a variable is mutated
  nowhere by core — so it degrades to no mutants without a special case.)
  """

  alias Mutare.Ecto.{Config, Island, Tag}
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Ecto.Host.{Catalog, Condition}

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Every single-point in-fragment mutant of a free-standing `dynamic/1,2` call, each the **whole
  call** rebuilt with one condition position swapped — the plugin's own catalog mutants as
  `Mutare.Ecto.Tag`s, the sub-contracted island mutants as producer-attributed
  `Mutare.Mutator.Mutation`s (passed through `Mutare.Ecto.mutate/2` untouched) — or `[]` when
  there is nothing to mutate (a body with no condition, or a top-level-pin body).

  The condition is located by `Mutare.Ecto.Host.Condition.locate/1`, which resolves both
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

    case Condition.locate(args) do
      %Condition{node: condition, index: index} ->
        # The shared in-fragment catalog, exactly what the hosted path composes
        # (`Mutare.Ecto.Host.Catalog.own_catalog/2`) — returned as raw tags: `Mutare.Ecto.mutate/2`
        # wraps every dispatched tag (`Tag.to_mutation/1`) and core's finalize pass applies the
        # `families:` filter and the equivalence note. Each tag is anchored at the condition node
        # it mutates (`Mutare.Ecto.Walk`), so although the *delivered* node is the whole rebuilt
        # call, the Site reports at the operator/literal itself — a line-scoped `# mutare:ignore`
        # reaches one comparison of a multi-line `dynamic`. For a top-level-pin body the catalog is
        # empty (a `^` has no SQL swap); the sub-contract below carries its interior to core.
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
  # (`Mutare.Ecto.Island.subcontracted/3`) — only delivery differs: each interior rebuild
  # is wrapped back into the **whole call** (the free-standing `dynamic`'s in-place shape) rather
  # than relayed as a bare condition for a weave to carry.
  defp subcontracted(condition, call, index, context),
    do: Island.subcontracted(condition, context, &QueryCall.replace_arg(call, index, &1))
end
