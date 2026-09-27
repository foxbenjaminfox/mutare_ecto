defmodule Mutare.Ecto.Host.JoinOn do
  @moduledoc false
  # Ecto combines repeated explicit on: expressions before escaping, so a dynamic woven
  # into one would sit below the root. Those predicates need whole-call reconstruction.
  # Association predicates are attached later, during planning; a sole explicit on: can
  # still host a root dynamic, whether the association source is named or anonymous.

  alias Mutare.Ecto.Surface
  alias Mutare.Ecto.AST.KeywordList
  alias Mutare.Ecto.AST.KeywordList.Entry

  @type receiver :: atom() | {:on, :combined}

  @spec from_receiver(atom(), KeywordList.t(), non_neg_integer()) :: receiver()
  def from_receiver(:on, %KeywordList{entries: entries}, index) do
    if MapSet.member?(hostable_from_indices(entries), index), do: :on, else: {:on, :combined}
  end

  def from_receiver(key, _clauses, _index), do: key

  @spec standalone_receiver([Macro.t()]) :: receiver()
  def standalone_receiver(args) do
    %KeywordList{entries: entries} = args |> List.last() |> KeywordList.parse()
    if Enum.count(entries, &(&1.key == :on)) == 1, do: :on, else: {:on, :combined}
  end

  @doc "The sole explicit on: of each join, independent of its source."
  @spec hostable_from_indices([Entry.t()]) :: MapSet.t(non_neg_integer())
  def hostable_from_indices(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce({nil, %{}}, &group_on/2)
    |> elem(1)
    |> Enum.flat_map(&hostable_group/1)
    |> MapSet.new()
  end

  defp group_on({%Entry{key: key}, index}, {join, groups}) do
    cond do
      Surface.from_clause?(key, :join_binding) -> {index, groups}
      key == :on -> {join, Map.update(groups, join, [index], &[index | &1])}
      true -> {join, groups}
    end
  end

  defp hostable_group({nil, _on_indices}), do: []
  defp hostable_group({_join, [index]}), do: [index]
  defp hostable_group({_join, _indices}), do: []
end
