defmodule Mutare.Ecto.RepoAggregate do
  @moduledoc """
  Swap the aggregate of a `Repo.aggregate/3` call along an SQL-meaningful ladder —
  `:sum`↔`:avg`, `:min`↔`:max`. A surviving mutant means no test distinguishes, say, the
  sum of a column from its average: the aggregate is computed but its *kind* is unchecked.

  `:count` is deliberately left alone, here as in the query-side catalog — see
  `Mutare.Ecto.Aggregate`.

  Matched by resolving the call's module to the configured `repo` (so the direct
  `MyApp.Repo.aggregate`, an aliased `Repo.aggregate`, and an imported form all match) and
  the function to `aggregate`. **Pipe-aware**: `q |> Repo.aggregate(:sum, :col)` carries the
  queryable as the piped left-hand side, so the aggregate atom sits one position earlier in
  the visible args — `Mutare.Mutator.visible_index/2` recovers where.
  """

  alias Mutare.Ecto.{Aggregate, AST, RepoCall, Tag}

  use Mutare.Ecto.SubMutator

  # The aggregate's effective argument position: aggregate(queryable, agg, field) → 1.
  @agg_position 1

  @doc "Aggregate-swap mutations for a `Repo.aggregate/3` node as labelled `:aggregate` tags, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [Tag.t()]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %{pipe_mode: pipe_mode} = context) do
    case RepoCall.resolve(node, context) do
      {:aggregate, args, rebuild} -> swap(args, rebuild, pipe_mode)
      _ -> []
    end
  end

  # The swap as an `:aggregate` tag labelled with the **source** function name (`"sum"`), so
  # `# mutare:ignore[ecto:sum]` names just this swap — matching the query-side aggregate family's
  # labelling.
  defp swap(args, rebuild, pipe_mode) do
    with index when is_integer(index) <- Mutare.Mutator.visible_index(@agg_position, pipe_mode),
         node when not is_nil(node) <- Enum.at(args, index),
         source = AST.atom_value(node),
         to when not is_nil(to) <- Aggregate.swap(source) do
      mutated = rebuild.(:aggregate, List.replace_at(args, index, Mutare.AST.literal(to)))
      [Tag.new(:aggregate, mutated, to_string(source))]
    else
      _ -> []
    end
  end
end
