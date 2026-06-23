defmodule Mutare.Ecto.Ordering do
  @moduledoc false
  # The shared direction-flip catalog for an `order_by` ordering value — used by both the
  # whole-`from` form (`Mutare.Ecto.Query`, where the ordering is a clause value) and the
  # standalone/pipe form (`Mutare.Ecto.Clause`, where it is the macro's last argument). Flips
  # `:asc`↔`:desc` and the four nulls-placement variants; one mutant per flippable direction
  # key, so a multi-key ordering yields one mutant per key.

  alias Mutare.Ecto.AST

  @direction_flips %{
    asc: :desc,
    desc: :asc,
    asc_nulls_first: :desc_nulls_last,
    desc_nulls_last: :asc_nulls_first,
    asc_nulls_last: :desc_nulls_first,
    desc_nulls_first: :asc_nulls_last
  }

  @doc """
  Mutated ordering values for `value` — one per flippable `direction: field` pair in the
  keyword list, each flipping just that direction. `[]` for a non-keyword ordering (a bare
  field or list of fields, which carry no explicit direction to flip). Sourceror wraps a list
  literal in a value position in a single-element `__block__`, so that is unwrapped first.
  """
  @spec flips(Macro.t()) :: [Macro.t()]
  def flips({:__block__, _meta, [inner]}), do: flips(inner)

  def flips(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      case flip_direction(pair) do
        nil -> []
        flipped -> [List.replace_at(value, index, flipped)]
      end
    end)
  end

  def flips(_value), do: []

  defp flip_direction({key, field}) do
    case @direction_flips[AST.atom_value(key)] do
      nil -> nil
      to -> {AST.keyword_key(to), field}
    end
  end

  defp flip_direction(_pair), do: nil
end
