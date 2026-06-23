defmodule Mutare.Ecto.Changeset do
  @moduledoc """
  Drop a transparent validation or constraint from a changeset pipeline — the changeset
  equivalent of removing a guard. `cs |> validate_required([:name])` → `cs`. A surviving
  mutant means **no test exercises the rule** that validation enforces.

  Every `Ecto.Changeset` validator/constraint here returns the changeset unchanged on the
  happy path, so dropping one is always compile-safe and behaviour-preserving *except* for
  the rule it removes. Matched by resolving the call to `Ecto.Changeset` (direct, aliased, or
  the common `import Ecto.Changeset`), so the form the source wrote doesn't matter.

  **Pipe-aware.** In a pipe (`cs |> validate_required(...)`) the changeset is the left-hand
  side, so the stage is replaced by `Function.identity/1` (`cs |> Function.identity()` ≡ `cs`,
  exactly Mutare's `CallRemoval` delivery). Written directly (`validate_required(cs, ...)`) the
  changeset is the first argument, so the call collapses to that argument.
  """

  alias Mutare.Transform.Calls

  @changeset_key [:Ecto, :Changeset]

  # Transparent validators and constraints — each returns the changeset, so dropping it only
  # removes its rule. Content-*producing* calls (`cast`, `change`, `put_change`, …) are NOT
  # here: dropping them changes the changeset's data, a different (and less focused) mutation.
  @droppable ~w(
    validate_required validate_length validate_format validate_number
    validate_inclusion validate_exclusion validate_subset validate_acceptance
    validate_confirmation validate_change unsafe_validate_unique
    unique_constraint foreign_key_constraint assoc_constraint no_assoc_constraint
    check_constraint exclusion_constraint
  )a

  @doc "Validation-drop mutations for an `Ecto.Changeset` validator/constraint call, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [Macro.t()]
  def mutations(node, %{pipe_mode: pipe_mode}) do
    case Calls.resolved_call(node) do
      {@changeset_key, fun, args, _rebuild} when fun in @droppable -> drop(pipe_mode, args)
      _ -> []
    end
  end

  def mutations(_node, _context), do: []

  # Piped: the changeset is the `|>` LHS, so the stage becomes identity on it. The absolute
  # `Elixir.Function` is alias-proof (a user `alias X, as: Function` can't redirect it).
  defp drop(:piped, _args), do: [identity_call()]
  # Direct: the changeset is the first argument; collapse the call to it.
  defp drop(:unpiped, [changeset | _rest]), do: [changeset]
  defp drop(:unpiped, []), do: []

  defp identity_call,
    do: {{:., [], [{:__aliases__, [], [:"Elixir", :Function]}, :identity]}, [], []}
end
