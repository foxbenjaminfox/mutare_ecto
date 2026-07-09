defmodule Mutare.Ecto.QueryTerminal do
  @moduledoc """
  Swap `Ecto.Query.first/1,2` ↔ `Ecto.Query.last/1,2` — the query "terminals" that restrict a
  query to a single edge of its ordering. `first` keeps the first row by the order (primary key
  ascending when none is given); `last` reverses it. Swapping them is a clean, same-arity rename
  (so it always compiles), behaviour-changing whenever the query can return more than one row — a
  survivor means no test pins *which* end the query is taking.

  These are plain `Ecto.Query` functions (not the macro DSL), so they resolve through
  `Mutare.Calls.resolved_call_to/3` in every written form — qualified (`Ecto.Query.first(q)`),
  aliased, or bare under `import Ecto.Query` — and ride Mutare's ordinary in-place selector. The
  `rebuild` keeps the source's written form (and is pipe-agnostic: `q |> first()` has an empty arg
  list, so `q |> last()` falls out for free). Family `:query_terminal`.
  """

  alias Mutare.Calls
  alias Mutare.Ecto.Tag

  @swaps %{first: :last, last: :first}
  @terminals Map.keys(@swaps)

  @behaviour Mutare.Ecto.SubMutator

  @doc "First↔last swap for an `Ecto.Query` terminal call as a `:query_terminal` tag, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [Tag.t()]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, _context) do
    case Calls.resolved_call_to(node, Ecto.Query, @terminals) do
      {:ok, fun, args, rebuild} -> [Tag.new(:query_terminal, rebuild.(@swaps[fun], args))]
      :error -> []
    end
  end
end
