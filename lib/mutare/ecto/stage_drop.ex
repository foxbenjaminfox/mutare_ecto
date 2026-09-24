defmodule Mutare.Ecto.StageDrop do
  @moduledoc false
  # Shared **stage drop** delivery for the two call-pipeline drop families —
  # `Mutare.Ecto.ClauseDrop` (a query clause stage) and `Mutare.Ecto.Changeset` (a changeset
  # validator/hook stage). Both remove one transparent stage from a call pipeline, and both do it
  # the same way (itself core's `CallRemoval` delivery): resolve the call to a module, map the
  # function to a family, and replace the stage with its passthrough — the value it threads,
  # which is the call's first argument. A pipe stage (`x |> step(…)`) reaches the plugin as the
  # direct call `step(x, …)`, so the same collapse serves both spellings; core keeps the written
  # pipe in the report, where the drop reads `x |> step(…)` → `x`.
  #
  # The owner module supplies the module it matches and a `fun -> family | nil` classifier
  # (nil = not droppable), keeping the family taxonomy with the family that owns it.

  alias Mutare.Calls
  alias Mutare.Ecto.{Config, Tag}

  @doc """
  Stage-drop mutations for `node` when it resolves (via `Mutare.Calls.resolved_call_to/3`) to a
  call on `module` whose function `family_fun` maps to a family. Returns `family`-tagged
  `Mutare.Ecto.Tag`s, or `[]` when the call is on another module or `family_fun` returns `nil`.
  """
  @spec mutations(Macro.t(), module(), (atom() -> Config.family() | nil)) :: [Tag.t()]
  def mutations(node, module, family_fun) do
    with {:ok, fun, args, _rebuild} <- Calls.resolved_call_to(node, module),
         family when not is_nil(family) <- family_fun.(fun) do
      for dropped <- drop(args), do: Tag.new(family, dropped)
    else
      _ -> []
    end
  end

  # The value the stage threads is its first argument; collapse the call to it. A call with no
  # argument threads nothing, so there is nothing to collapse to.
  defp drop([value | _rest]), do: [value]
  defp drop([]), do: []
end
