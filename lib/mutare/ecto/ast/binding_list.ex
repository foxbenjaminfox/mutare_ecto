defmodule Mutare.Ecto.AST.BindingList do
  @moduledoc false
  # A parsed Ecto binding **declaration** — a written list literal whose every element is an entry
  # of `Mutare.Ecto.Binding`'s grammar — with enough wrapper information to rebuild it exactly.
  #
  # `parse/1` answers one question only: *is this node a declaration the plugin can interpret?*
  # The empty `[]` is one (it declares exactly nothing). Which declarations are **reorderable** is
  # a narrower, separate question, answered by `transpositions/1` alone — a list of named or
  # indexed entries is a perfectly good declaration with nothing to transpose.
  #
  # `:error` means "not a declaration the plugin can interpret" and nothing more. Whether that is
  # harmless (the node was never a declaration — a `select` list, a keyword shorthand) or a
  # reason not to re-declare (the node *is* the declaration, by position, and the plugin cannot
  # read it) is the caller's knowledge, not this module's: `find/1` searches by shape and may
  # skip it; `Mutare.Ecto.Host.Condition` and `Mutare.Ecto.Host.Bindings` know the slot and must
  # not.

  alias Mutare.Ecto.{AST, Binding}

  @enforce_keys [:node, :entries]
  defstruct [:node, :entries]

  @typedoc "`entries` are the parsed elements of `node`'s list, one per written element, in order."
  @type t :: %__MODULE__{node: Macro.t(), entries: [Binding.entry()]}

  @doc "The parsed declaration for `node` — a list literal of binding entries, `[]` included — or `:error`."
  @spec parse(Macro.t()) :: {:ok, t()} | :error
  def parse(node) do
    with elements when is_list(elements) <- AST.unwrap_list(node),
         {:ok, entries} <- parse_entries(elements) do
      {:ok, %__MODULE__{node: node, entries: entries}}
    else
      _ -> :error
    end
  end

  # All-or-nothing: one entry outside the grammar makes the whole declaration uninterpretable.
  defp parse_entries(elements) do
    parsed = Enum.map(elements, &Binding.parse/1)

    if Enum.all?(parsed, &match?({:ok, _entry}, &1)),
      do: {:ok, for({:ok, entry} <- parsed, do: entry)},
      else: :error
  end

  @doc """
  The first **non-empty** declaration in `nodes`, with its index, or `nil` — the shape-based
  search the in-place reorder uses (`Mutare.Ecto.BindingReorder`), over macros whose binding slot
  it does not know by position. Skipping a list it cannot interpret costs that reorder its
  mutants and nothing else; a consumer that *re-declares* the list must locate it by position
  instead (see the module comment).
  """
  @spec find([Macro.t()]) :: {non_neg_integer(), t()} | nil
  def find(nodes) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.find_value(fn {node, index} ->
      case parse(node) do
        {:ok, %__MODULE__{entries: [_ | _]} = list} -> {index, list}
        _other -> nil
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

  # The swap exchanges the **written** elements (so each keeps its own meta), which `parse/1`
  # guarantees line up one-to-one with `entries`.
  defp swap(%__MODULE__{node: node}, left, right) do
    elements = AST.unwrap_list(node)
    a = Enum.at(elements, left)
    b = Enum.at(elements, right)
    AST.rewrap_list(node, elements |> List.replace_at(left, b) |> List.replace_at(right, a))
  end
end
