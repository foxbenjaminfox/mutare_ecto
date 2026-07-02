defmodule Mutare.Ecto.SubMutator do
  @moduledoc false
  # The uniform contract every Ecto sub-mutator implements. `Mutare.Ecto.Dispatcher` classifies a
  # node, invokes only the relevant producers (`RepoAggregate`, `Changeset`, `Query`, …), and merges
  # their results through this shared callback shape.
  #
  # `mutations/2` takes the AST `node` and the mutation `context` (carrying `:config` — the
  # `init/1`-parsed `families:`/`dialects:`/`repo:` `%Config{}` — and `:pipe_mode`), and returns the
  # `{family, node}` mutation pairs it produces, or `[]`. A sub-mutator that needs neither config
  # nor pipe-mode simply ignores the context; `Mutare.Ecto.mutate/2` returns the merged pairs as
  # tagged `Mutation`s (`Mutare.Ecto.Config.tagged/1`), and the `families:` filter + equivalence
  # note are applied once, by core, via `Mutare.Ecto.finalize/2`. A sub-mutator that
  # *sub-contracts* islands to core's generation (`Mutare.Ecto.Dynamic`) additionally returns
  # producer-attributed `Mutare.Mutator.Mutation`s, which pass through `Config.tagged/1` untouched
  # and core's finalize pass bypasses — the mutant is a core family's, not one of the plugin's.
  #
  # A sub-mutator whose first `mutations/2` clause pattern-matches the context *shape* (e.g.
  # `%{pipe_mode: …}`) needs a defensive catch-all so a context lacking that key returns `[]` rather
  # than raising. `use Mutare.Ecto.SubMutator` supplies both the behaviour and that catch-all
  # (appended via `@before_compile`), so the boilerplate and its rationale live here once. A
  # sub-mutator with a *total* `mutations/2` (one that matches any node/context and returns `[]`
  # itself) instead writes `@behaviour Mutare.Ecto.SubMutator` directly — a `use` there would inject
  # an unreachable clause.

  alias Mutare.Ecto.Config

  @typedoc """
  One produced mutation: its SQL `family` and mutated `node`, optionally with a finer
  `# mutare:ignore` label (a swap's operator / a value's kind — see `Mutare.Ecto.Config.tagged/1`).
  A structural family omits the label; a swap/value family appends it.
  """
  @type tagged ::
          {family :: Config.family(), mutated :: Macro.t()}
          | {family :: Config.family(), mutated :: Macro.t(),
             label :: String.t() | [String.t()] | nil}

  @callback mutations(node :: Macro.t(), context :: Mutare.Mutator.context()) :: [
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
