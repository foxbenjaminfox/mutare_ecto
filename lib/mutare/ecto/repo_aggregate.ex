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

  alias Mutare.Ecto.AST
  alias Mutare.Transform.Calls

  # The aggregate's effective argument position: aggregate(queryable, agg, field) → 1.
  @agg_position 1
  @swaps %{sum: :avg, avg: :sum, min: :max, max: :min}

  @doc "Aggregate-swap mutations for a `Repo.aggregate/3` node, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [Macro.t()]
  def mutations(node, %{opts: opts, pipe_mode: pipe_mode}) do
    with repo when not is_nil(repo) <- repo_key(opts),
         {^repo, :aggregate, args, rebuild} <- Calls.resolved_call(node) do
      swap(args, rebuild, pipe_mode)
    else
      _ -> []
    end
  end

  def mutations(_node, _context), do: []

  defp repo_key(opts) do
    case Keyword.get(opts, :repo) do
      nil -> nil
      module -> AST.module_key(module)
    end
  end

  defp swap(args, rebuild, pipe_mode) do
    index = Mutare.Mutator.visible_index(@agg_position, pipe_mode)

    with node when not is_nil(node) <- index && Enum.at(args, index),
         to when not is_nil(to) <- @swaps[AST.atom_value(node)] do
      [rebuild.(:aggregate, List.replace_at(args, index, AST.atom_literal(to)))]
    else
      _ -> []
    end
  end
end
