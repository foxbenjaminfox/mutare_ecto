defmodule Mutare.Ecto.Host.JoinOn do
  @moduledoc false
  # Decides which join `on:` conditions the host may weave a `^dynamic` into.
  #
  # Ecto accepts a `^dynamic(...)` only as the **entire, top-level** on-expression of a join. When a
  # join carries more than one on-condition — two `on:` keys, or an `assoc(...)` join whose implicit
  # join condition Ecto folds in with `and` — each condition becomes an operand of that `and`, and a
  # `^dynamic` operand is rejected ("dynamic expressions can only be interpolated at the top level of
  # where, having, group_by, order_by, select, update or a join's on"). A `where:`/`having:` clause
  # never hits this — each is its own independent `BooleanExpr`, so its `^dynamic` *is* top-level — so
  # only `on:` needs the guard (`BUG-multi-condition-join-on.md`).
  #
  # Skipping a non-hostable `on:` drops only the in-fragment operator mutants on that one condition;
  # the whole-`from` families (JoinType, the join's clause drop) still apply to it.

  alias Mutare.Ecto.Surface
  alias Mutare.Ecto.AST.KeywordList.Entry

  @doc """
  The indices of `on:` entries in a `from` clause list that are safe to host: the **sole** `on:` of a
  non-`assoc` join. Every other `on:` — a join with two `on:` keys, or any `assoc(...)` join's `on:`
  (its implicit condition is folded in) — is excluded.
  """
  @spec hostable_from_indices([Entry.t()]) :: MapSet.t(non_neg_integer())
  def hostable_from_indices(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce({nil, %{}}, &group_on/2)
    |> elem(1)
    |> Enum.flat_map(&hostable_group/1)
    |> MapSet.new()
  end

  @doc """
  Whether a standalone `join/4,5`'s lone `on:` is safe to host: the call has exactly one `on:` option
  and a non-`assoc` source (`join(q, :inner, [p], c in Schema, on: …)`, not `c in assoc(p, :x)` —
  whose implicit condition Ecto would fold the hosted `^dynamic` under).
  """
  @spec hostable_standalone?([Macro.t()], [Entry.t()]) :: boolean()
  def hostable_standalone?(args, option_entries) do
    Enum.count(option_entries, &(&1.key == :on)) == 1 and not Enum.any?(args, &assoc_value?/1)
  end

  # File each `on:` under the join it belongs to. A join key (any binding-declaring join — `join`,
  # `inner_join`, `left_join`, `cross_join`, the laterals, …) opens a new group keyed by its own
  # (unique) index and carrying its source value; each following `on:` joins that group. An `on:`
  # before any join (`nil` group) is malformed and stays unhostable.
  defp group_on({%Entry{key: key, value: value}, index}, {join, groups}) do
    cond do
      Surface.from_clause?(key, :join_binding) -> {{index, value}, groups}
      key == :on -> {join, Map.update(groups, join, [index], &[index | &1])}
      true -> {join, groups}
    end
  end

  # A group's `on:` is hostable only when the join is real, has exactly one `on:`, and is not an
  # `assoc` join. Anything else (no owning join, multiple `on:`, an assoc source) yields nothing.
  defp hostable_group({nil, _on_indices}), do: []
  defp hostable_group({_join, [_, _ | _]}), do: []

  defp hostable_group({{_join_index, value}, [index]}),
    do: if(assoc_value?(value), do: [], else: [index])

  # A join source `x in assoc(p, :rel)` — its implicit join condition forces the `and` fold. Every
  # other source (a schema, table, subquery, bound query) contributes only its explicit `on:`.
  defp assoc_value?({:__block__, _meta, [inner]}), do: assoc_value?(inner)
  defp assoc_value?({:in, _meta, [_lhs, rhs]}), do: assoc_call?(rhs)
  defp assoc_value?(_node), do: false

  defp assoc_call?({:__block__, _meta, [inner]}), do: assoc_call?(inner)
  defp assoc_call?({:assoc, _meta, [_source, _name]}), do: true
  defp assoc_call?(_node), do: false
end
