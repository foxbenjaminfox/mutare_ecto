defmodule Mutare.Ecto.RepoAggregate do
  @moduledoc """
  Swap the aggregate of a `Repo.aggregate/3` call along an SQL-meaningful ladder —
  `:sum`↔`:avg`, `:min`↔`:max`. A surviving mutant means no test distinguishes, say, the
  sum of a column from its average: the aggregate is computed but its *kind* is unchecked.

  `:count` is deliberately left alone — it has a different arity contract
  (`aggregate(q, :count)`), and swapping it for a value aggregate would change the call's
  shape, not just its meaning.

  Matched by resolving the call's module to the configured `repo` (so the direct
  `MyApp.Repo.aggregate`, an aliased `Repo.aggregate`, and an imported form all match) and
  the function to `aggregate`. **Pipe-aware**: `q |> Repo.aggregate(:sum, :col)` carries the
  queryable as the piped left-hand side, so the aggregate atom sits one position earlier in
  the visible args — `Mutare.Mutator.visible_index/2` recovers where.
  """

  alias Mutare.Ecto.{Aggregate, AST, RepoCall}

  @behaviour Mutare.Ecto.SubMutator

  # The aggregate's effective argument position: aggregate(queryable, agg, field) → 1.
  @agg_position 1

  @doc "Aggregate-swap mutations for a `Repo.aggregate/3` node as `{:aggregate, node}` pairs, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [{:aggregate, Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %{pipe_mode: pipe_mode} = context) do
    case RepoCall.resolve(node, context) do
      {:aggregate, args, rebuild} ->
        for mutated <- swap(args, rebuild, pipe_mode), do: {:aggregate, mutated}

      _ ->
        []
    end
  end

  # mutare:ignore[clause_drop] equivalent — the first clause matches every node given core's `%{opts:, pipe_mode:}` context; this fallback only guards a context missing one of those keys, which core never sends
  def mutations(_node, _context), do: []

  defp swap(args, rebuild, pipe_mode) do
    index = Mutare.Mutator.visible_index(@agg_position, pipe_mode)

    with node when not is_nil(node) <- index && Enum.at(args, index),
         to when not is_nil(to) <- Aggregate.swap(AST.atom_value(node)) do
      [rebuild.(:aggregate, List.replace_at(args, index, AST.atom_literal(to)))]
    else
      _ -> []
    end
  end
end
