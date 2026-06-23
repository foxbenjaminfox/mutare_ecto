defmodule Mutare.Ecto.Query do
  @moduledoc """
  Whole-`from` query mutations — the ones expressible **without** Mutare's foreign-semantics
  DSL host (Bucket 1 of `DESIGN.md`). Each returns a whole mutated `from(...)` node, which
  Mutare's ordinary in-place selector wraps; the localized in-fragment mutations (operator
  swaps inside a `where`, via `^`/`dynamic`) arrive with the host extensions.

    * **Clause drop** — remove one `where`/`having`/`or_where`/`or_having` clause from the
      query. "Is this filter tested?" Reuses the surviving clauses, so it always compiles, and
      works for both the binding form (`from p in Post, where: p.active`) and the bindingless
      form (`from Post, where: [active: true]`) since it operates on the clause list, not the
      clause value.
    * **Order flip** — flip an `order_by` direction (`:asc`↔`:desc`, and the `*_nulls_*`
      variants). "Does any test pin the sort direction?"

  A `from` node is `{:from, meta, [source, clauses]}` where `clauses` is a keyword list (in
  Sourceror form, each key wrapped as `{:__block__, [format: :keyword], [atom]}`). `from/1`
  (`from(Post)`, no clauses) yields nothing.
  """

  alias Mutare.Ecto.AST

  @droppable ~w(where having or_where or_having)a
  @direction_flips %{
    asc: :desc,
    desc: :asc,
    asc_nulls_first: :desc_nulls_last,
    desc_nulls_last: :asc_nulls_first,
    asc_nulls_last: :desc_nulls_first,
    desc_nulls_first: :asc_nulls_last
  }

  @doc "Whole-`from` mutations for a `from(...)` node, or `[]`."
  @spec mutations(Macro.t()) :: [Macro.t()]
  def mutations({:from, meta, [source, clauses]}) when is_list(clauses) do
    clause_drops(meta, source, clauses) ++ order_flips(meta, source, clauses)
  end

  def mutations(_node), do: []

  defp clause_drops(meta, source, clauses) do
    for {pair, index} <- Enum.with_index(clauses), clause_key(pair) in @droppable do
      {:from, meta, [source, List.delete_at(clauses, index)]}
    end
  end

  defp order_flips(meta, source, clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      if clause_key(pair) == :order_by do
        for flipped <- flip_orderings(clause_value(pair)) do
          {:from, meta, [source, List.replace_at(clauses, index, put_value(pair, flipped))]}
        end
      else
        []
      end
    end)
  end

  # An `order_by` value is a keyword list of `direction: field` (e.g. `[asc: :name, desc: :id]`).
  # Produce one mutant per flippable direction key, each flipping just that key. Sourceror wraps a
  # list literal in a value position in a single-element `__block__` (to anchor its metadata), so
  # unwrap that before treating it as a list.
  defp flip_orderings({:__block__, _meta, [inner]}), do: flip_orderings(inner)

  defp flip_orderings(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      case flip_direction(pair) do
        nil -> []
        flipped -> [List.replace_at(value, index, flipped)]
      end
    end)
  end

  defp flip_orderings(_value), do: []

  defp flip_direction({key, field}) do
    case @direction_flips[AST.atom_value(key)] do
      nil -> nil
      to -> {AST.keyword_key(to), field}
    end
  end

  defp flip_direction(_pair), do: nil

  defp clause_key({key, _value}), do: AST.atom_value(key)
  defp clause_key(_node), do: nil

  defp clause_value({_key, value}), do: value
  defp put_value({key, _old}, value), do: {key, value}
end
