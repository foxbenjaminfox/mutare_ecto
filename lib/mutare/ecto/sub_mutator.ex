defmodule Mutare.Ecto.SubMutator do
  @moduledoc false
  # The uniform contract every Ecto sub-mutator implements. `Mutare.Ecto.Dispatcher` classifies a
  # node, invokes only the relevant producers (`RepoAggregate`, `Changeset`, `Query`, …), and merges
  # their results through this shared callback shape.
  #
  # `mutations/2` takes a `node` and the plugin's `%Mutare.Ecto.Context{}` — core's callback
  # context, unpacked once into the parsed `%Config{}` (`Mutare.Ecto.Config`), core's `pipe_mode`,
  # and the run's enabled specs (`mutators`, for the island sub-contract; `Mutare.Ecto.Context`) —
  # and returns the `%Mutare.Ecto.Tag{}`s it produces, or `[]`. The struct is total, so a producer
  # ignores the context or pattern-matches just the keys it wants (`%Context{pipe_mode: mode}`)
  # and never guards a context *shape*. Production is pure: `Mutare.Ecto.mutate/2` wraps the
  # merged tags via `Mutare.Ecto.Tag.to_mutation/1`, and the `families:` filter + equivalence note
  # are applied by core's `finalize/2` (`Mutare.Ecto.Equivalence`). A sub-mutator that
  # sub-contracts pin interiors to core (`Mutare.Ecto.Dynamic`) additionally returns
  # producer-attributed `Mutare.Mutator.Mutation`s, which pass through untouched
  # (`Mutare.Ecto.Island`).
  #
  # `node` is a raw AST `Macro.t()` for most sub-mutators (`RepoAggregate`, `RepoWrite`,
  # `Changeset`, `ClauseDrop`, `QueryTerminal`) — `Mutare.Ecto.Dispatcher` hands them the node
  # exactly as `Mutare.Calls.resolved_call/1` classified it. The four query-macro sub-mutators
  # (`Clause`, `Query`, `Dynamic`, `BindingReorder`) instead receive the already-normalized
  # `Mutare.Ecto.AST.QueryCall.t()` Dispatcher builds via `QueryCall.parse/1` before dispatch, since
  # every registered query macro is guaranteed to carry its macro-identity stamp by the time
  # `mutate/2` runs (`Mutare.Transform.Resolve` stamps the whole tree first) — so those four never
  # need to re-parse a raw node themselves.
  #
  # Every sub-mutator declares `@behaviour Mutare.Ecto.SubMutator` directly — there is nothing to
  # `use`: with the context a struct, no producer needs an injected fallback clause.

  alias Mutare.Ecto.AST.QueryCall

  @typedoc "One produced mutation — the uniform `%Mutare.Ecto.Tag{}` (see `Mutare.Ecto.Tag`)."
  @type tagged :: Mutare.Ecto.Tag.t()

  @callback mutations(node :: Macro.t() | QueryCall.t(), context :: Mutare.Ecto.Context.t()) :: [
              tagged() | Mutare.Mutator.Mutation.t()
            ]
end
