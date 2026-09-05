defmodule Mutare.Ecto.RepoCall do
  @moduledoc false
  # Shared resolve-and-guard preamble for the Repo-call families (`Mutare.Ecto.RepoWrite`,
  # `Mutare.Ecto.RepoAggregate`). Both match a call on one of the configured `repo:` modules and
  # then dispatch on the function, so the "is this a call on one of our repos?" step — resolve the
  # call's module, require it to be among the configured keys — lives here once rather than in each
  # family's `with`. The matched repo travels with the call, because the `:persistence` rewrite
  # restates it (`Mutare.Ecto.RepoWrite`'s `:repo` stamp). This mirrors how `Mutare.Ecto.StageDrop`
  # factors the resolve-and-classify shape for the pipeline drop families.

  alias Mutare.Calls
  alias Mutare.Ecto.{Config, Context}

  @doc """
  Resolve `node` to a `{repo, fun, args, rebuild}` call on one of the context's configured `repo:`
  modules — `repo` being the matched module's key — or `nil` when no `repo:` is set, the node is
  not a resolved call, or it targets another module. The caller then dispatches on `fun` (and
  re-emits each mutant in the source's written form via `rebuild`).
  """
  @spec resolve(Macro.t(), Context.t()) ::
          {Calls.module_key(), atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | nil
  def resolve(node, %Context{config: config}) do
    with {repo, _fun, _args, _rebuild} = call <- Calls.resolved_call(node),
         true <- repo in Config.repo_keys(config) do
      call
    else
      _ -> nil
    end
  end
end
