defmodule Mutare.Ecto.QueryTerminal do
  @moduledoc """
  Swap `Ecto.Query.first/1,2` ↔ `Ecto.Query.last/1,2` — the query "terminals" that restrict a
  query to a single edge of its ordering. `first` keeps the first row by the order (primary key
  ascending when none is given); `last` reverses it. Swapping them is a clean, same-arity rename
  (so it always compiles), behaviour-changing whenever the query can return more than one row — a
  survivor means no test pins *which* end the query is taking.

  These are plain `Ecto.Query` functions (not the macro DSL), so they resolve through
  `Mutare.Transform.Calls` in every written form — qualified (`Ecto.Query.first(q)`), aliased, or
  bare under `import Ecto.Query` — and ride Mutare's ordinary in-place selector. The `rebuild`
  keeps the source's written form (and is pipe-agnostic: `q |> first()` has an empty arg list, so
  `q |> last()` falls out for free). Family `:query_terminal`.
  """

  alias Mutare.Transform.Calls

  @query_key [:Ecto, :Query]
  @swaps %{first: :last, last: :first}
  @terminals Map.keys(@swaps)

  @doc "First↔last swap for an `Ecto.Query` terminal call as a `{:query_terminal, node}` pair, or `[]`."
  @spec mutations(Macro.t()) :: [{:query_terminal, Macro.t()}]
  def mutations(node) do
    case Calls.resolved_call(node) do
      {@query_key, fun, args, rebuild} when fun in @terminals ->
        [{:query_terminal, rebuild.(@swaps[fun], args)}]

      _ ->
        []
    end
  end
end
