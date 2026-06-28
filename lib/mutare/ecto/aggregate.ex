defmodule Mutare.Ecto.Aggregate do
  @moduledoc false
  # The shared aggregate walker of the Aggregate family: swap an aggregate call
  # along its SQL-meaningful ladder — `sum`↔`avg`, `min`↔`max` — wherever it appears inside a
  # query expression. An expression is an arbitrary shape (a bare call, a tuple, a list, a map, a
  # keyword list of them), so `swaps/1` walks the whole structure and returns one *single-point*
  # mutant per aggregate position — each the expression with exactly one aggregate swapped.
  #
  # Callers feed it three positions: a `select`/`select_merge` value and an `order_by` value
  # (both whole-`from` and standalone/pipe — `Mutare.Ecto.Query`/`Mutare.Ecto.Clause`, delivered
  # in place), and a `where`/`having` condition (`Mutare.Ecto.Host`, delivered `^`/`dynamic`-hosted
  # so a `having: sum(p.x) > n` swaps its aggregate behind the same selector as its operators).
  #
  # `count` is deliberately excluded (as in `Mutare.Ecto.RepoAggregate`): swapping it for a
  # value aggregate changes the result's meaning in a way its `:distinct`/arity contract makes
  # awkward, and `count`↔a-value-aggregate is rarely a focused, killable mutation.

  @agg_swaps %{sum: :avg, avg: :sum, min: :max, max: :min}
  @agg_funcs Map.keys(@agg_swaps)

  @doc """
  Every single-point aggregate swap of select-expression `expr` as `{:aggregate, node, label}`
  triples, or `[]` — the self-tagging `{family, node, label}` contract the other shared catalogs
  (`Mutare.Ecto.Fragment.mutants/2`, `Mutare.Ecto.Ordering.flips/1`) use, so a caller threads the
  family and finer label uniformly when it rebuilds the surrounding clause. `label` is the **source**
  function the swap mutates (`"sum"` for `sum`↔`avg`), so `# mutare:ignore[ecto:sum]` names just it.
  """
  @spec swaps(Macro.t()) :: [{:aggregate, Macro.t(), String.t()}]
  def swaps(expr), do: for({node, label} <- walk(expr), do: {:aggregate, node, label})

  @doc false
  # The finer `# mutare:ignore` labels the aggregate family can emit — each swappable function name,
  # derived from the swap table so the vocabulary can't drift from what's produced. Folded into the
  # plugin's variant vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels, do: @agg_swaps |> Map.keys() |> Enum.map(&to_string/1)

  @doc """
  The SQL-meaningful swap of a single aggregate function name (`:sum`↔`:avg`, `:min`↔`:max`), or
  `nil` for a non-aggregate. Used by `Mutare.Ecto.RepoAggregate` to swap the *atom* form
  (`Repo.aggregate(q, :sum, …)`) against the same ladder this walker swaps the *call* form along.
  """
  @spec swap(atom()) :: atom() | nil
  def swap(name), do: Map.get(@agg_swaps, name)

  # An aggregate call: offer its swap (a same-arity rename, so it always compiles), then descend
  # into its arguments so a nested aggregate (`max(sum(...))` — degenerate but harmless) is still
  # reached. The function name is the call form atom (not a wrapped literal), so the rename keeps
  # the call's meta and renders cleanly. Each mutant is paired with the **source** function name
  # (`"sum"`), the `# mutare:ignore` label naming the swap; descent carries the descendant's label.
  defp walk({f, meta, args}) when f in @agg_funcs and is_list(args) do
    [{{@agg_swaps[f], meta, args}, to_string(f)} | lift_args(f, meta, args)]
  end

  # Any other call/operator node (atom form or a remote `{:., …}` form): descend into args.
  defp walk({form, meta, args}) when is_list(args), do: lift_args(form, meta, args)

  # A 2-tuple literal — a `{a, b}` select, or a keyword/map pair: descend into both sides.
  defp walk({left, right}) do
    # mutare:ignore[operand_swap] branch order is irrelevant — mutants are consumed as a set
    for({m, label} <- walk(left), do: {{m, right}, label}) ++
      for({m, label} <- walk(right), do: {{left, m}, label})
  end

  # A list — a list select, the args of a `%{}`/`{}` node, or a keyword list: descend per element.
  defp walk(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, i} ->
      for {m, label} <- walk(el), do: {List.replace_at(list, i, m), label}
    end)
  end

  # Atoms, literals, variables, field references: no aggregate here.
  defp walk(_node), do: []

  defp lift_args(form, meta, args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, i} ->
      for {m, label} <- walk(arg), do: {{form, meta, List.replace_at(args, i, m)}, label}
    end)
  end
end
