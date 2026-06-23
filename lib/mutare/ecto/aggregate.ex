defmodule Mutare.Ecto.Aggregate do
  @moduledoc false
  # The select-expression half of the Aggregate family (`DESIGN.md`): swap an aggregate call
  # along its SQL-meaningful ladder — `sum`↔`avg`, `min`↔`max` — wherever it appears inside a
  # `select`/`select_merge` expression. A select expression is an arbitrary shape (a bare call,
  # a tuple, a list, a map, a keyword list of them), so `swaps/1` walks the whole structure and
  # returns one *single-point* mutant per aggregate position — each the expression with exactly
  # one aggregate swapped.
  #
  # `count` is deliberately excluded (as in `Mutare.Ecto.RepoAggregate`): swapping it for a
  # value aggregate changes the result's meaning in a way its `:distinct`/arity contract makes
  # awkward, and `count`↔a-value-aggregate is rarely a focused, killable mutation.

  @agg_swaps %{sum: :avg, avg: :sum, min: :max, max: :min}
  @agg_funcs Map.keys(@agg_swaps)

  @doc "Every single-point aggregate swap of select-expression `expr`, or `[]`."
  @spec swaps(Macro.t()) :: [Macro.t()]
  def swaps(expr), do: walk(expr)

  # An aggregate call: offer its swap (a same-arity rename, so it always compiles), then descend
  # into its arguments so a nested aggregate (`max(sum(...))` — degenerate but harmless) is still
  # reached. The function name is the call form atom (not a wrapped literal), so the rename keeps
  # the call's meta and renders cleanly.
  defp walk({f, meta, args}) when f in @agg_funcs and is_list(args) do
    [{@agg_swaps[f], meta, args} | lift_args(f, meta, args)]
  end

  # Any other call/operator node (atom form or a remote `{:., …}` form): descend into args.
  defp walk({form, meta, args}) when is_list(args), do: lift_args(form, meta, args)

  # A 2-tuple literal — a `{a, b}` select, or a keyword/map pair: descend into both sides.
  defp walk({left, right}) do
    for(m <- walk(left), do: {m, right}) ++ for(m <- walk(right), do: {left, m})
  end

  # A list — a list select, the args of a `%{}`/`{}` node, or a keyword list: descend per element.
  defp walk(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, i} ->
      for m <- walk(el), do: List.replace_at(list, i, m)
    end)
  end

  # Atoms, literals, variables, field references: no aggregate here.
  defp walk(_node), do: []

  defp lift_args(form, meta, args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, i} ->
      for m <- walk(arg), do: {form, meta, List.replace_at(args, i, m)}
    end)
  end
end
