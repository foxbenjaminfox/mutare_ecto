defmodule Mutare.Ecto.AST.KeywordList do
  @moduledoc false
  # A normalized keyword/clause list that preserves each key node and the list's Sourceror wrapper.
  # Every edit (`put_value/3`, `put_key/3`, `delete_at/2`, `reject_key/2`, `take/2`) returns a new
  # list, so edits compose; `to_ast/1` renders the result.

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

  @doc "The empty list (a bare `[]`) — what a clause-less `from(source)` declares."
  @spec empty() :: t()
  def empty, do: %__MODULE__{node: [], entries: []}

  @doc "Render the list back to AST, preserving its Sourceror wrapper."
  @spec to_ast(t()) :: Macro.t()
  def to_ast(%__MODULE__{node: node, entries: entries}),
    do: AST.rewrap_list(node, Enum.map(entries, &entry_ast/1))

  @doc "The list truncated to its first `count` entries — same wrapper, a prefix of the entries."
  @spec take(t(), non_neg_integer()) :: t()
  def take(%__MODULE__{entries: entries} = list, count),
    do: %{list | entries: Enum.take(entries, count)}

  @doc """
  Flat-map `fun.(entry, index)` over the entries, in written order — the shared "for each clause,
  produce results" skeleton behind the whole-`from` mutators (`Mutare.Ecto.Query`), the subquery
  interior walks (`Mutare.Ecto.Subquery`), and the host's from-clause targets (`Mutare.Ecto.Host`).
  """
  @spec flat_map(t(), (Entry.t(), non_neg_integer() -> [term()])) :: [term()]
  def flat_map(%__MODULE__{entries: entries}, fun) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} -> fun.(entry, index) end)
  end

  @doc "Like `flat_map/2`, visiting only the entries whose *key* satisfies `key_filter`."
  @spec flat_map(t(), (atom() -> boolean()), (Entry.t(), non_neg_integer() -> [term()])) ::
          [term()]
  def flat_map(%__MODULE__{} = list, key_filter, fun) do
    flat_map(list, fn entry, index ->
      if key_filter.(entry.key), do: fun.(entry, index), else: []
    end)
  end

  @doc """
  Whether the entry at `index` is the last one carrying its key — no later entry repeats it. A
  purely structural question; what a repeated key *means* is the caller's
  (`Mutare.Ecto.AST.FromCall.effective_clause?/2`).
  """
  @spec last_of_key?(t(), non_neg_integer()) :: boolean()
  def last_of_key?(%__MODULE__{entries: entries}, index) do
    [%Entry{key: key} | later] = Enum.drop(entries, index)
    not Enum.any?(later, &(&1.key == key))
  end

  @doc "The list with a new `value` for the entry at `index` — same wrapper, one value swapped."
  @spec put_value(t(), non_neg_integer(), Macro.t()) :: t()
  def put_value(%__MODULE__{entries: entries} = list, index, value) do
    entries = List.update_at(entries, index, fn %Entry{} = entry -> %{entry | value: value} end)
    %__MODULE__{list | entries: entries}
  end

  @doc "The list without every entry keyed `key` — same wrapper, the other entries kept."
  @spec reject_key(t(), atom()) :: t()
  def reject_key(%__MODULE__{entries: entries} = list, key),
    do: %__MODULE__{list | entries: Enum.reject(entries, &(&1.key == key))}

  @doc "The list with the entry at `index` re-keyed `key` (a fresh key node; the value kept)."
  @spec put_key(t(), non_neg_integer(), atom()) :: t()
  def put_key(%__MODULE__{entries: entries} = list, index, key) do
    entries =
      List.update_at(entries, index, fn %Entry{} = entry ->
        %{entry | key: key, key_node: Mutare.AST.keyword_key(key)}
      end)

    %__MODULE__{list | entries: entries}
  end

  @doc "The list without the entries at `indices` — same wrapper, the other entries kept in order."
  @spec delete_at(t(), [non_neg_integer()]) :: t()
  def delete_at(%__MODULE__{entries: entries} = list, indices) when is_list(indices) do
    kept = for {entry, index} <- Enum.with_index(entries), index not in indices, do: entry
    %__MODULE__{list | entries: kept}
  end

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
