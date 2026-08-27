defmodule Mutare.Ecto.SubMutator do
  @moduledoc false
  # The uniform contract every Ecto sub-mutator implements. `Mutare.Ecto.Dispatcher` classifies a
  # node, invokes only the relevant producers (`RepoAggregate`, `Changeset`, `Query`, …), and merges
  # their results through this shared callback shape.
  #
  # `mutations/2` takes a `node` and the mutation `context` (carrying `:config` — the
  # `init/1`-parsed `families:`/`dialects:`/`repo:` `%Config{}` — and `:pipe_mode`), and returns the
  # `%Mutare.Ecto.Tag{}`s it produces, or `[]`. A sub-mutator that needs neither config nor
  # pipe-mode simply ignores the context; `Mutare.Ecto.mutate/2` returns the merged tags as
  # `Mutation`s (`Mutare.Ecto.Tag.to_mutation/1`), and the `families:` filter + equivalence
  # note are applied once, by core, via `Mutare.Ecto.finalize/2`. A sub-mutator that
  # *sub-contracts* islands to core's generation (`Mutare.Ecto.Dynamic`) additionally returns
  # producer-attributed `Mutare.Mutator.Mutation`s, which pass through `Tag.to_mutation/1` untouched
  # and core's finalize pass bypasses — the mutant is a core family's, not one of the plugin's.
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

  @typedoc """
  One produced mutation — the uniform `%Mutare.Ecto.Tag{}`: its SQL `family` and mutated `node`,
  optionally a finer `# mutare:ignore` `label` (a swap's operator / a value's kind — a structural
  family leaves it `nil`; see `Mutare.Ecto.Tag.to_mutation/1`) and, for a whole-`from` rewrite
  (`Mutare.Ecto.Query`), an `attribution` (`Mutation.at/2`/`at_drop/1`) so its site is reported at
  the inner clause it changed, not the whole `from`.
  """
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
