defmodule Mutare.Ecto.RepoCall do
  @moduledoc false
  # Shared resolve-and-guard preamble for the Repo-call families (`Mutare.Ecto.RepoWrite`,
  # `Mutare.Ecto.RepoAggregate`). Both match a call on the configured `repo:` and then dispatch on
  # the function, so the "is this a call on our repo?" step — read the repo key from context, resolve
  # the call's module, require the two to match — lives here once rather than in each family's `with`.
  # This mirrors how `Mutare.Ecto.StageDrop` factors the resolve-and-classify shape for the pipeline
  # drop families.

  alias Mutare.Calls
  alias Mutare.Ecto.Config

  @doc """
  Resolve `node` to a `{fun, args, rebuild}` call on the context's configured `repo`, or `nil` when
  no `repo:` is set, the node is not a resolved call, or it targets another module. The caller then
  dispatches on `fun` (and re-emits each mutant in the source's written form via `rebuild`).
  """
  @spec resolve(Macro.t(), map()) ::
          {atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | nil
  def resolve(node, context) do
    with repo when not is_nil(repo) <- context |> Config.from_context() |> Config.repo_key(),
         {:ok, fun, args, rebuild} <- Calls.resolved_call_to(node, repo) do
      {fun, args, rebuild}
    else
      _ -> nil
    end
  end
end
