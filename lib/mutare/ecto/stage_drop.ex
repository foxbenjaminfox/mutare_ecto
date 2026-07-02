defmodule Mutare.Ecto.StageDrop do
  @moduledoc false
  # Shared pipe-aware **stage drop** delivery for the two call-pipeline drop families —
  # `Mutare.Ecto.ClauseDrop` (a query clause stage) and `Mutare.Ecto.Changeset` (a changeset
  # validator/hook stage). Both remove one transparent stage from a call pipeline, and both do it
  # the same way (itself core's `CallRemoval` delivery): resolve the call to a module, map the
  # function to a family, and replace the stage with its passthrough.
  #
  #   * **piped** (`x |> step(…)`) — the value is the `|>` left side, so the stage becomes
  #     `Function.identity/1` (`x |> Function.identity()` ≡ `x`). `Elixir.Function` is alias-proof
  #     (a user `alias X, as: Function` can't redirect it).
  #   * **direct** (`step(x, …)`) — the value is the first argument, so the call collapses to it.
  #
  # The owner module supplies the module it matches and a `fun -> family | nil` classifier
  # (nil = not droppable), keeping the family taxonomy with the family that owns it.

  alias Mutare.Calls
  alias Mutare.Ecto.Config

  @doc """
  Stage-drop mutations for `node` when it resolves (via `Mutare.Calls.resolved_call_to/3`) to a
  call on `module` whose function `family_fun` maps to a family. Returns `{family, node}` pairs,
  or `[]` when the call is on another module or `family_fun` returns `nil`. Pipe-aware via
  `pipe_mode`.
  """
  @spec mutations(
          Macro.t(),
          module(),
          (atom() -> Config.family() | nil),
          :piped | :unpiped
        ) ::
          [{Config.family(), Macro.t()}]
  def mutations(node, module, family_fun, pipe_mode) do
    with {:ok, fun, args, _rebuild} <- Calls.resolved_call_to(node, module),
         family when not is_nil(family) <- family_fun.(fun) do
      for dropped <- drop(pipe_mode, args), do: {family, dropped}
    else
      _ -> []
    end
  end

  # Piped: the value is the `|>` LHS, so the stage becomes identity on it. Direct: the value is the
  # first argument; collapse the call to it.
  defp drop(:piped, _args), do: [identity_call()]
  defp drop(:unpiped, [value | _rest]), do: [value]
  defp drop(:unpiped, []), do: []

  defp identity_call, do: Mutare.AST.absolute_call([:Function], :identity, [])
end
