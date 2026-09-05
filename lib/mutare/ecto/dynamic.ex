defmodule Mutare.Ecto.Dynamic do
  @moduledoc """
  In-fragment SQL mutations for a **free-standing** `dynamic/1,2` call — the condition a user
  builds ahead of time and splices later:

      d = dynamic([p], p.views > 100)
      Repo.all(where(query, ^d))

  The condition body is the same SQL fragment a hosted `where`/`having` owns, so the same catalog
  walks it (`Mutare.Ecto.Fragment`, scalar and aggregate swaps folded in — `sum`↔`avg` for a
  dynamic destined for a `having`). This closes the loop the `where(q, ^d)` splice site leaves
  open: a top-level `^d` is hosted there like any other condition, but the catalog stops at the
  pin and the island sub-contract finds only a bare variable inside, which core mutates nowhere
  (`Mutare.Ecto.Island`) — the splice contributes nothing of its own, so the `dynamic` is
  *mutated where it is built*. This module is that build site.

  **Delivery** differs from the hosted path. `dynamic` is registered `:raw`
  (`Mutare.Ecto.Surface.macro_registrations/0`), so core never descends into its DSL arguments —
  but core still offers the *whole call* to `mutate/2` (which is why it is `:raw`, not the
  call-level `:skip`: a skipped call is an inert leaf nobody is offered), and a free-standing `dynamic` sits in an
  ordinary expression position (its value is a runtime `%Ecto.Query.DynamicExpr{}`, not a spliced
  query clause). So each mutant is the whole call rebuilt with exactly one point of the condition
  swapped, delivered by Mutare's ordinary in-place selector `case` — the same Bucket-1 delivery as
  the whole-`from` rewrites in `Mutare.Ecto.Query`. No host / `^`-weaving is needed, each selector
  branch invokes the `dynamic` macro independently, and exactly one `DynamicExpr` builds per run.
  Each mutant is still **reported at the mutated expression** — the walk anchors it
  (`Mutare.Ecto.Walk`) — so a line-scoped `# mutare:ignore` reaches one comparison of a
  multi-line `dynamic`.

  The written binding list is re-emitted byte-for-byte (its positional reorder is
  `Mutare.Ecto.BindingReorder`'s). A `^` pin's interior — nested (`p.x > ^(min + 1)`) or the whole
  body (`dynamic([p], ^(if params.sort, do: a, else: b))`) — is never this catalog's: it is
  sub-contracted to core through the same seam the host uses (`Mutare.Ecto.Island`), only
  delivered as this module's whole-call rewrite instead of a weave.
  """

  alias Mutare.Ecto.{Context, Island, Tag}
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Ecto.Host.{Catalog, Condition}

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Every single-point in-fragment mutant of a free-standing `dynamic/1,2` call, each the **whole
  call** rebuilt with one condition position swapped — the plugin's own catalog mutants as
  `Mutare.Ecto.Tag`s, the sub-contracted island mutants as producer-attributed
  `Mutare.Mutator.Mutation`s — or `[]` when there is nothing to mutate. The condition is located
  by `Mutare.Ecto.Host.Condition.locate/1`, exactly as for a standalone `where`.
  """
  @spec mutations(QueryCall.t(), Context.t()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
  @impl Mutare.Ecto.SubMutator
  # `Mutare.Ecto.Dispatcher` only reaches here once it has already classified the call as the
  # `:dynamic` macro kind, and `Mutare.Ecto.Surface` registers that kind on exactly the `:dynamic`
  # name — so `call.name` is always `:dynamic` by the time this runs.
  def mutations(%QueryCall{name: :dynamic, args: args} = call, %Context{config: config} = context) do
    case Condition.locate(args) do
      %Condition{node: condition, index: index} ->
        # The shared in-fragment catalog (`Mutare.Ecto.Host.Catalog.own_catalog/2`), each tag
        # rebuilt into the whole call; its anchor survives the rebuild (`Tag.map_node/2`). For a
        # top-level-pin body the catalog is empty — the sub-contract below carries its interior.
        own =
          for tag <- Catalog.own_catalog(condition, config),
              do: Tag.map_node(tag, &QueryCall.replace_arg(call, index, &1))

        # mutare:ignore[operand_swap] equivalent — two independent mutant lists, consumed as a set
        own ++ subcontracted(condition, call, index, context)

      nil ->
        []
    end
  end

  # The island sub-contract (`Mutare.Ecto.Island.subcontracted/3`), delivered as the whole call.
  defp subcontracted(condition, call, index, context),
    do: Island.subcontracted(condition, context, &QueryCall.replace_arg(call, index, &1))
end
