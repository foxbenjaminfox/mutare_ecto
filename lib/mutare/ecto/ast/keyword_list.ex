defmodule Mutare.Ecto.AST.KeywordList do
  @moduledoc false
  # A normalized keyword/clause list that preserves each key node and the list's Sourceror wrapper.

  alias Mutare.Ecto.AST

  defmodule Entry do
    @moduledoc false
    @enforce_keys [:key, :key_node, :value]
    defstruct [:key, :key_node, :value]

    @type t :: %__MODULE__{key: atom(), key_node: Macro.t(), value: Macro.t()}
  end

  @enforce_keys [:node, :entries]
  defstruct [:node, :entries]

  @type t :: %__MODULE__{node: Macro.t(), entries: [Entry.t()]}

  @doc "The normalized list for `node`, or `nil` unless it is a keyword list keyed entirely by atoms."
  @spec parse(Macro.t()) :: t() | nil
  def parse(node) do
    with list when is_list(list) <- AST.unwrap_list(node),
         {:ok, entries} <- parse_entries(list) do
      %__MODULE__{node: node, entries: entries}
    else
      _ -> nil
    end
  end

  @doc "Like `parse/1`, but rejects (returns `nil` for) an empty list."
  @spec nonempty(Macro.t()) :: t() | nil
  def nonempty(node) do
    case parse(node) do
      %__MODULE__{entries: [_ | _]} = list -> list
      _ -> nil
    end
  end

  @doc "Render the list back to AST, preserving its Sourceror wrapper."
  @spec to_ast(t()) :: Macro.t()
  def to_ast(%__MODULE__{node: node, entries: entries}),
    do: AST.rewrap_list(node, Enum.map(entries, &entry_ast/1))

  @doc "Render the list with a new `value` for the entry at `index`."
  @spec replace_value(t(), non_neg_integer(), Macro.t()) :: Macro.t()
  def replace_value(%__MODULE__{entries: entries} = list, index, value) do
    entries = List.update_at(entries, index, fn %Entry{} = entry -> %{entry | value: value} end)
    to_ast(%__MODULE__{list | entries: entries})
  end

  @doc "Render the list with a new `key` (and matching key node) for the entry at `index`."
  @spec replace_key(t(), non_neg_integer(), atom()) :: Macro.t()
  def replace_key(%__MODULE__{entries: entries} = list, index, key) do
    entries =
      List.update_at(entries, index, fn %Entry{} = entry ->
        %{entry | key: key, key_node: Mutare.AST.keyword_key(key)}
      end)

    to_ast(%__MODULE__{list | entries: entries})
  end

  @doc "Render the list with the entry at `index` (or entries at a list of indices) removed."
  @spec delete(t(), non_neg_integer() | [non_neg_integer()]) :: Macro.t()
  def delete(%__MODULE__{entries: entries} = list, indices) when is_list(indices) do
    kept =
      entries
      |> Enum.with_index()
      |> Enum.reject(fn {_entry, index} -> index in indices end)
      |> Enum.map(fn {entry, _index} -> entry end)

    to_ast(%__MODULE__{list | entries: kept})
  end

  def delete(%__MODULE__{entries: entries} = list, index),
    do: to_ast(%__MODULE__{list | entries: List.delete_at(entries, index)})

  defp parse_entries(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      {key_node, value}, {:ok, entries} ->
        case AST.atom_value(key_node) do
          key when is_atom(key) and not is_nil(key) ->
            entry = %Entry{key: key, key_node: key_node, value: value}
            {:cont, {:ok, [entry | entries]}}

          _other ->
            {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      :error -> :error
    end
  end

  defp entry_ast(%Entry{key_node: key, value: value}), do: {key, value}
end
