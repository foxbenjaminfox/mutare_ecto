defmodule Mutare.Ecto.AST.BindingList do
  @moduledoc false
  # A validated, non-empty Ecto binding list with enough wrapper information to rebuild it exactly.

  alias Mutare.Ecto.{AST, Binding}

  @enforce_keys [:node, :entries]
  defstruct [:node, :entries]

  @type t :: %__MODULE__{node: Macro.t(), entries: [Macro.t()]}

  @doc "The validated binding list for `node` (a non-empty list of binding entries), or `nil`."
  @spec parse(Macro.t()) :: t() | nil
  def parse(node) do
    case AST.unwrap_list(node) do
      [_ | _] = entries ->
        if Enum.all?(entries, &Binding.entry?/1),
          do: %__MODULE__{node: node, entries: entries},
          else: nil

      _ ->
        nil
    end
  end

  @doc "The first binding list in `nodes`, with its index, or `nil`."
  @spec find([Macro.t()]) :: {non_neg_integer(), t()} | nil
  def find(nodes) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.find_value(fn {node, index} ->
      case parse(node) do
        %__MODULE__{} = list -> {index, list}
        nil -> nil
      end
    end)
  end

  defp reorderables(%__MODULE__{entries: entries}) do
    for {entry, index} <- Enum.with_index(entries),
        name = Binding.reorderable_name(entry),
        not is_nil(name),
        do: {index, name}
  end

  @doc "Every single pairwise transposition of the reorderable positional bindings."
  @spec transpositions(t()) :: [Macro.t()]
  def transpositions(%__MODULE__{} = list) do
    bindings = reorderables(list)

    for {left, left_name} <- bindings,
        {right, right_name} <- bindings,
        left < right,
        left_name != right_name,
        do: swap(list, left, right)
  end

  defp replace_entries(%__MODULE__{node: node}, entries), do: AST.rewrap_list(node, entries)

  defp swap(%__MODULE__{entries: entries} = list, left, right) do
    a = Enum.at(entries, left)
    b = Enum.at(entries, right)
    replace_entries(list, entries |> List.replace_at(left, b) |> List.replace_at(right, a))
  end
end
