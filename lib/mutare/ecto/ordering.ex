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
  #
  # ## Implicit-direction flip
  #
  # A bare ordering term — `order_by(q, :name)`, `order_by(q, [u], u.name)`, or a bare field in a
  # list (`[u.name, desc: u.age]`) — carries **no written key**, but Ecto sorts it ascending, so
  # the author's implicit assertion is `asc`. We flip it to an explicit `desc` re-tag (`:name` →
  # `desc: :name`), a `:ordering` mutant with a behaviourally-distinct, *deterministic* baseline.
  # This deliberately replaces the old `order_by` **clause drop**, whose "kill" depended on the
  # database returning rows in an order that happened to differ from the sorted one — result order
  # without `ORDER BY` is unspecified by SQL, so that mutant's survival was a function of engine
  # nondeterminism, not the test suite. The flip is the reliable question ("is this ordering
  # exercised?") the drop was pretending to ask. Only a plain field is re-tagged: a `^`-pinned
  # runtime ordering, a `fragment`, or a computed expression is left untouched (flipping it would
  # mutate a value, not a direction).

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

  # A bare ordering term is implicitly ascending, so its implicit-direction flip is labelled `asc`
  # — the same finer label an explicit `asc: field` flip carries.
  @implicit_label "asc"

  @doc """
  Mutated ordering values for `value` as `{family, mutated_value}` pairs — one per mutated axis
  per entry: an explicitly-keyed `direction: field` pair flips its direction (`:ordering`) and, if
  nulls-qualified, its placement (`:ordering_nulls`); a bare, implicitly-ascending term (`:name`,
  `u.name`) gets its implicit `asc` re-tagged `desc` (`:ordering`). `[]` for a term we don't
  re-tag (a `^`-pinned ordering, a `fragment`, a computed expression). Sourceror wraps a list
  literal in a value position in a single-element `__block__`, so that is unwrapped first.
  """
  @spec flips(Macro.t()) :: [{:ordering | :ordering_nulls, Macro.t(), String.t()}]
  def flips({:__block__, _meta, [inner]}) when is_list(inner), do: flips(inner)

  def flips(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      for {family, flipped, label} <- axis_flips(entry) do
        {family, List.replace_at(value, index, flipped), label}
      end
    end)
  end

  # A lone ordering term (not a list): re-tag its implicit `asc` to an explicit `desc` keyword
  # list, or nothing when it isn't a plain field we re-tag.
  def flips(value) do
    case implicit_desc(value) do
      nil -> []
      pair -> [{:ordering, [pair], @implicit_label}]
    end
  end

  @doc false
  # The finer `# mutare:ignore` labels the ordering families emit — the direction axis (`asc`/`desc`)
  # and the nulls-placement axis (`nulls_first`/`nulls_last`), derived from the flip tables so the
  # vocabulary can't drift. Folded into the plugin's variant vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels do
    directions = @direction_flips |> Map.keys() |> Enum.map(&direction_label/1) |> Enum.uniq()
    placements = @nulls_flips |> Map.keys() |> Enum.map(&placement_label/1) |> Enum.uniq()
    # Sort for determinism: `Map.keys` iteration order over atom keys is unspecified and varies
    # with runtime atom-table state, so the raw concatenation is non-deterministic.
    Enum.sort(directions ++ placements)
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

  # A bare list element — an implicitly-ascending field — re-tagged descending in place, or `[]`
  # when it isn't a plain field we re-tag.
  defp axis_flips(element) do
    case implicit_desc(element) do
      nil -> []
      pair -> [{:ordering, pair, @implicit_label}]
    end
  end

  # The descending keyword pair for a bare, implicitly-ascending ordering term, or `nil` when the
  # term isn't a plain field: a `^`-pinned runtime ordering, a `fragment`, an opaque qualified
  # helper call, or any computed expression is left untouched (flipping it would mutate a value, not
  # a direction). A written `:name` (block-wrapped atom), `u.name` / `as(:u).name` (field access),
  # or bare binding var is `asc` by definition, so `desc: term` is a reliable,
  # behaviourally-distinct ordering mutant.
  defp implicit_desc({:__block__, _meta, [atom]} = term) when is_atom(atom), do: desc_pair(term)

  defp implicit_desc({{:., _meta, [receiver, field]}, _outer, []} = term)
       when is_atom(field) do
    if field_receiver?(receiver), do: desc_pair(term)
  end

  defp implicit_desc({name, _meta, ctx} = term) when is_atom(name) and is_atom(ctx),
    do: desc_pair(term)

  defp implicit_desc(_term), do: nil

  defp field_receiver?({name, _meta, ctx})
       when is_atom(name) and is_atom(ctx) and name != :__MODULE__,
       do: true

  defp field_receiver?({name, _meta, args}) when name in [:as, :parent_as] and is_list(args),
    do: true

  defp field_receiver?(_receiver), do: false

  defp desc_pair(term), do: {Mutare.AST.keyword_key(:desc), term}

  defp tag(_family, nil, _field, _direction), do: []

  defp tag(:ordering, to, field, direction),
    do: [{:ordering, {Mutare.AST.keyword_key(to), field}, direction_label(direction)}]

  defp tag(:ordering_nulls, to, field, direction),
    do: [{:ordering_nulls, {Mutare.AST.keyword_key(to), field}, placement_label(direction)}]

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
