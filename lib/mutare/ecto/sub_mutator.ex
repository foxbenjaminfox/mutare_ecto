defmodule Mutare.Ecto.SubMutator do
  @moduledoc false
  # The uniform contract every Ecto sub-mutator implements. `Mutare.Ecto` is a thin front that runs
  # each node past a family of sub-mutators (`RepoAggregate`, `Changeset`, `Query`, …) and merges
  # their results; this behaviour gives them one shape so the dispatcher is a plain fold over a list
  # rather than a hand-written call per mutator with its own arity.
  #
  # `mutations/2` takes the AST `node` and the mutation `context` (carrying `:opts` — the
  # `families:`/`dialects:` config — and `:pipe_mode`), and returns the `{family, node}` mutation
  # pairs it produces, or `[]`. A sub-mutator that needs neither opts nor pipe-mode simply ignores
  # the context; `Mutare.Ecto.mutate/2` then filters the merged pairs by the configured `families:`.

  @callback mutations(node :: Macro.t(), context :: Mutare.Mutator.context()) ::
              [{family :: atom(), mutated :: Macro.t()}]
end
