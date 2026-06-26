defmodule Mutare.Ecto.Changeset do
  @moduledoc """
  Drop a transparent step from a changeset pipeline — the changeset equivalent of removing a
  guard. `cs |> validate_required([:name])` → `cs`. A surviving mutant means **no test
  exercises** the behaviour that step contributes. Matched by resolving the call to
  `Ecto.Changeset` (direct, aliased, or the common `import Ecto.Changeset`), so the form the
  source wrote doesn't matter.

  Two families, dropped by the same machinery but kept apart because the thing being removed
  differs:

    * **`:validation_drop`** — a validator or constraint (`validate_required`, `unique_constraint`,
      …). Each returns the changeset unchanged on the happy path, so dropping it is always
      behaviour-preserving *except* for the rule it enforces. A survivor means the rule is untested.
    * **`:hook_drop`** — a deferred Repo-time hook (`prepare_changes`, `optimistic_lock`). These
      are **not** validators: they register code/locks the Repo runs at `insert`/`update` time
      (a counter bump, a derived column, a stale-version guard). Dropping one is still
      compile-safe and changeset-shape-preserving, but the gap it surfaces is "this side effect /
      concurrency guard is never asserted", a different question — so it gets its own family.

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

  # Deferred Repo-time hooks — they register code/locks the Repo runs at insert/update time,
  # not a validation rule. Same drop mechanics, distinct family (`:hook_drop`); see the moduledoc.
  @hooks ~w(prepare_changes optimistic_lock)a

  @doc """
  Changeset-step drop mutations for an `Ecto.Changeset` call as `{family, node}` pairs, or `[]`.
  A validator/constraint drops under `:validation_drop`; a Repo-time hook under `:hook_drop`.
  """
  @spec mutations(Macro.t(), Mutare.Mutator.context()) ::
          [{:validation_drop | :hook_drop, Macro.t()}]
  def mutations(node, %{pipe_mode: pipe_mode}) do
    case Calls.resolved_call(node) do
      {@changeset_key, fun, args, _rebuild} ->
        case family(fun) do
          nil -> []
          family -> for mutated <- drop(pipe_mode, args), do: {family, mutated}
        end

      _ ->
        []
    end
  end

  # mutare:ignore[clause_drop] equivalent — the first clause matches every node given core's `%{pipe_mode:}` context; this fallback only guards a context without that key, which core never sends
  def mutations(_node, _context), do: []

  defp family(fun) when fun in @droppable, do: :validation_drop
  defp family(fun) when fun in @hooks, do: :hook_drop
  defp family(_fun), do: nil

  # Piped: the changeset is the `|>` LHS, so the stage becomes identity on it. The absolute
  # `Elixir.Function` is alias-proof (a user `alias X, as: Function` can't redirect it).
  defp drop(:piped, _args), do: [identity_call()]
  # Direct: the changeset is the first argument; collapse the call to it.
  defp drop(:unpiped, [changeset | _rest]), do: [changeset]
  defp drop(:unpiped, []), do: []

  defp identity_call,
    do: {{:., [], [{:__aliases__, [], [:"Elixir", :Function]}, :identity]}, [], []}
end
