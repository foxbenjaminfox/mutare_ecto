defmodule Mutare.Ecto.AST.BindingList do
  @moduledoc false
  # A validated, non-empty Ecto binding list with enough wrapper information to rebuild it exactly.

  alias Mutare.Ecto.Binding

  @enforce_keys [:node, :entries]
  defstruct [:node, :entries]

  @type t :: %__MODULE__{node: Macro.t(), entries: [Macro.t()]}

  @spec parse(Macro.t()) :: t() | nil
  def parse(node) do
    case unwrap(node) do
      [_ | _] = entries ->
        if Enum.all?(entries, &Binding.entry?/1),
          do: %__MODULE__{node: node, entries: entries},
          else: nil

      _ ->
        nil
    end
  end

  @spec positionals(t()) :: [{non_neg_integer(), atom()}]
  def positionals(%__MODULE__{entries: entries}) do
    for {entry, index} <- Enum.with_index(entries),
        Binding.variable?(entry),
        do: {index, Binding.variable_name(entry)}
  end

  @spec replace_entries(t(), [Macro.t()]) :: Macro.t()
  def replace_entries(%__MODULE__{node: {:__block__, meta, [_old]}}, entries),
    do: {:__block__, meta, [entries]}

  def replace_entries(%__MODULE__{}, entries), do: entries

  @spec swap(t(), non_neg_integer(), non_neg_integer()) :: Macro.t()
  def swap(%__MODULE__{entries: entries} = list, left, right) do
    a = Enum.at(entries, left)
    b = Enum.at(entries, right)
    replace_entries(list, entries |> List.replace_at(left, b) |> List.replace_at(right, a))
  end

  defp unwrap({:__block__, _meta, [list]}) when is_list(list), do: list
  defp unwrap(list) when is_list(list), do: list
  defp unwrap(_node), do: nil
end
