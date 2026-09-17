defmodule Mutare.Ecto.Dynamic do
  @moduledoc """
  In-fragment SQL mutations for a **free-standing** `dynamic/1,2` call — the condition a user
  builds ahead of time and splices later:

      d = dynamic([p], p.views > 100)
      Repo.all(where(query, ^d))

  The condition body is the same SQL fragment a hosted `where`/`having` contains, so the same catalog
  walks it (`Mutare.Ecto.Fragment`, scalar and aggregate swaps folded in — `sum`↔`avg` for a
  dynamic used in a `having`). At the `where(q, ^d)` splice site, a top-level `^d` is hosted
  like any other condition, but the catalog stops at the pin. Its interior contains only a bare
  variable, which core does not mutate (`Mutare.Ecto.Island`). The splice therefore produces no
  mutations; this module mutates the `dynamic` *where it is built*.

  **Delivery** differs from the hosted path. `dynamic` is registered `:raw`
  (`Mutare.Ecto.Surface.macro_registrations/0`), so core never descends into its DSL arguments —
  but core still offers the *whole call* to `mutate/2` (which is why it is `:raw`, not the
  call-level `:skip`: a skipped call is never passed to a mutator), and a free-standing `dynamic`
  sits in an ordinary expression position (its value is a runtime `%Ecto.Query.DynamicExpr{}`, not a spliced
  query clause). So each mutant is the whole call rebuilt with exactly one point of the condition
  swapped, delivered by Mutare's ordinary in-place selector `case` — the same Bucket-1 delivery as
  the whole-`from` rewrites in `Mutare.Ecto.Query`. No host / `^`-weaving is needed, each selector
  branch invokes the `dynamic` macro independently, and exactly one `DynamicExpr` builds per run.
  Each mutant is still **reported at the mutated expression** — the walk anchors it
  (`Mutare.Ecto.Walk`) — so a line-scoped `# mutare:ignore` reaches one comparison of a
  multi-line `dynamic`.

  The written binding list is re-emitted byte-for-byte (`Mutare.Ecto.BindingReorder` handles
  positional reordering). A `^` pin's interior — nested (`p.x > ^(min + 1)`) or the whole
  body (`dynamic([p], ^(if params.sort, do: a, else: b))`) — is never mutated by this catalog: it is
  passed to core through the same interface the host uses (`Mutare.Ecto.Island`), only
  delivered as this module's whole-call rewrite instead of a weave.
  """

  alias Mutare.Ecto.{Context, Island, Tag}
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Ecto.Host.{Catalog, Condition}

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Every single-point in-fragment mutant of a free-standing `dynamic/1,2` call, each the **whole
  call** rebuilt with one condition position swapped — the plugin's own catalog mutants as
  `Mutare.Ecto.Tag`s, the island mutants returned by core as producer-attributed
  `Mutare.Mutator.Mutation`s — or `[]` when there is nothing to mutate. The condition is located
  by `Mutare.Ecto.Host.Condition.locate/3`, exactly as for a standalone `where` — but its
  declaration is never read: the whole-call rebuild re-emits the written list as it stands, so
  even one the plugin cannot interpret (which a woven `dynamic/2` could not re-declare) is
  mutated here.
  """
  @spec mutations(QueryCall.t(), Context.t()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
  @impl Mutare.Ecto.SubMutator
  # `Mutare.Ecto.Dispatcher` only reaches here once it has already classified the call as the
  # `:dynamic` macro kind, and `Mutare.Ecto.Surface` registers that kind on exactly the `:dynamic`
  # name — so `call.name` is always `:dynamic` by the time this runs.
  def mutations(
        %QueryCall{name: :dynamic, args: args, pipe_mode: pipe_mode} = call,
        %Context{config: config} = context
      ) do
    case Condition.locate(:dynamic, args, pipe_mode) do
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
