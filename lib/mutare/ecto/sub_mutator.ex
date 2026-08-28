defmodule Mutare.Ecto.SubMutator do
  @moduledoc false
  # The uniform contract every Ecto sub-mutator implements. `Mutare.Ecto.Dispatcher` classifies a
  # node, invokes only the relevant producers (`RepoAggregate`, `Changeset`, `Query`, …), and merges
  # their results through this shared callback shape.
  #
  # `mutations/2` takes a `node` and the mutation `context` (carrying `:config` — the parsed
  # `%Config{}`, `Mutare.Ecto.Config` — and `:pipe_mode`), and returns the `%Mutare.Ecto.Tag{}`s
  # it produces, or `[]`. Production is pure: `Mutare.Ecto.mutate/2` wraps the merged tags via
  # `Mutare.Ecto.Tag.to_mutation/1`, and the `families:` filter + equivalence note are applied by
  # core's `finalize/2` (`Mutare.Ecto.Equivalence`). A sub-mutator that sub-contracts pin
  # interiors to core (`Mutare.Ecto.Dynamic`) additionally returns producer-attributed
  # `Mutare.Mutator.Mutation`s, which pass through untouched (`Mutare.Ecto.Island`).
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
  # A sub-mutator whose first `mutations/2` clause pattern-matches the context *shape* (e.g.
  # `%{pipe_mode: …}`) needs a defensive catch-all so a context lacking that key returns `[]` rather
  # than raising. `use Mutare.Ecto.SubMutator` supplies both the behaviour and that catch-all
  # (appended via `@before_compile`), so the boilerplate and its rationale live here once. A
  # sub-mutator with a *total* `mutations/2` (one that matches any node/context and returns `[]`
  # itself) instead writes `@behaviour Mutare.Ecto.SubMutator` directly — a `use` there would inject
  # an unreachable clause.

  alias Mutare.Ecto.AST.QueryCall

  @typedoc "One produced mutation — the uniform `%Mutare.Ecto.Tag{}` (see `Mutare.Ecto.Tag`)."
  @type tagged :: Mutare.Ecto.Tag.t()

  @callback mutations(node :: Macro.t() | QueryCall.t(), context :: Mutare.Mutator.context()) :: [
              tagged() | Mutare.Mutator.Mutation.t()
            ]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Mutare.Ecto.SubMutator
      @before_compile Mutare.Ecto.SubMutator
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      # mutare:ignore[clause_drop] equivalent — core always sends the full context shape the preceding clause matches, so this defensive catch-all is unreachable from any real run
      def mutations(_node, _context), do: []
    end
  end
end
