defmodule Mutare.Ecto.Ordering do
  @moduledoc false
  # The shared direction-flip catalog for an `order_by` ordering value — used by both the
  # whole-`from` form (`Mutare.Ecto.Query`, where the ordering is a clause value) and the
  # standalone/pipe form (`Mutare.Ecto.Clause`, where it is the macro's last argument).
  #
  # A nulls-qualified key carries **two independent axes**, each mutated on its own — never
  # both at once:
  #
  #   * **direction** (`:ordering`) — `:asc`↔`:desc`, keeping the nulls placement
  #     (`:asc_nulls_last`→`:desc_nulls_last`). Killable by any test that pins the sort order.
  #   * **nulls placement** (`:ordering_nulls`) — `*_nulls_first`↔`*_nulls_last`, keeping the
  #     direction (`:asc_nulls_first`→`:asc_nulls_last`). **Only** for an explicitly nulls-
  #     qualified key: writing `:asc_nulls_first` is the author *asserting they care where NULLs
  #     sort*, so an untested placement is a real gap — whereas a bare `:asc`/`:desc` makes no
  #     such claim and gets only the direction flip. This axis is equivalence-sensitive (it
  #     needs NULL rows in the result to kill), so it is recorded under its own family.
  #
  # So a bare `:asc` yields one mutant (direction); an `:asc_nulls_first` yields two (direction
  # and placement), each flipping exactly one axis. Flipping both at once — the earlier
  # behaviour — was a *weaker* mutant: any order-pinning test killed it, so a missing
  # NULL-placement assertion never surfaced.

  alias Mutare.Ecto.AST

  # Direction axis: flip `:asc`↔`:desc`, preserving any nulls qualifier. One target per key.
  @direction_flips %{
    asc: :desc,
    desc: :asc,
    asc_nulls_first: :desc_nulls_first,
    desc_nulls_first: :asc_nulls_first,
    asc_nulls_last: :desc_nulls_last,
    desc_nulls_last: :asc_nulls_last
  }

  # Nulls-placement axis: flip `*_nulls_first`↔`*_nulls_last`, preserving the direction. Only
  # the explicitly-qualified keys appear — a bare `:asc`/`:desc` declares no placement to flip.
  @nulls_flips %{
    asc_nulls_first: :asc_nulls_last,
    asc_nulls_last: :asc_nulls_first,
    desc_nulls_first: :desc_nulls_last,
    desc_nulls_last: :desc_nulls_first
  }

  @doc """
  Mutated ordering values for `value` as `{family, mutated_value}` pairs — one per axis per
  flippable `direction: field` pair in the keyword list, each flipping just that one axis (the
  direction under `:ordering`, the nulls placement under `:ordering_nulls`). `[]` for a
  non-keyword ordering (a bare field or list of fields, which carry no explicit direction).
  Sourceror wraps a list literal in a value position in a single-element `__block__`, so that
  is unwrapped first.
  """
  @spec flips(Macro.t()) :: [{:ordering | :ordering_nulls, Macro.t(), String.t()}]
  def flips({:__block__, _meta, [inner]}), do: flips(inner)

  def flips(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      for {family, flipped, label} <- axis_flips(pair) do
        {family, List.replace_at(value, index, flipped), label}
      end
    end)
  end

  def flips(_value), do: []

  @doc false
  # The finer `# mutare:ignore` labels the ordering families emit — the direction axis (`asc`/`desc`)
  # and the nulls-placement axis (`nulls_first`/`nulls_last`), derived from the flip tables so the
  # vocabulary can't drift. Folded into the plugin's variant vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels do
    directions = @direction_flips |> Map.keys() |> Enum.map(&direction_label/1) |> Enum.uniq()
    placements = @nulls_flips |> Map.keys() |> Enum.map(&placement_label/1) |> Enum.uniq()
    directions ++ placements
  end

  # Every single-axis flip of one `direction: field` pair, tagged with its family **and** the axis
  # value it mutates — the direction (`asc`/`desc`) under `:ordering`, the placement (`nulls_first`/
  # `nulls_last`) under `:ordering_nulls` — so `# mutare:ignore[ecto:asc]` names just the asc flip.
  # The label fns are read lazily inside `tag/4` (only when a flip exists), so a non-direction key
  # never reaches them.
  defp axis_flips({key, field}) do
    direction = AST.atom_value(key)

    # mutare:ignore[operand_swap] axis order is irrelevant — flips are consumed as a set
    tag(:ordering, @direction_flips[direction], field, direction) ++
      tag(:ordering_nulls, @nulls_flips[direction], field, direction)
  end

  defp axis_flips(_pair), do: []

  defp tag(_family, nil, _field, _direction), do: []

  defp tag(:ordering, to, field, direction),
    do: [{:ordering, {AST.keyword_key(to), field}, direction_label(direction)}]

  defp tag(:ordering_nulls, to, field, direction),
    do: [{:ordering_nulls, {AST.keyword_key(to), field}, placement_label(direction)}]

  # The direction half of a sort key (`:asc_nulls_first` → `"asc"`); every flippable key starts asc/desc.
  defp direction_label(direction) do
    case to_string(direction) do
      "asc" <> _ -> "asc"
      "desc" <> _ -> "desc"
    end
  end

  # The nulls-placement half of a qualified key (`:asc_nulls_first` → `"nulls_first"`); only the
  # `@nulls_flips` keys reach `placement_label/1` (via `tag(:ordering_nulls, …)` with a non-nil flip).
  defp placement_label(direction) do
    case to_string(direction) do
      "asc_" <> placement -> placement
      "desc_" <> placement -> placement
    end
  end
end
