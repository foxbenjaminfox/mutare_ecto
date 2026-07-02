defmodule Mutare.Ecto.Aggregate do
  @moduledoc false
  # The shared aggregate catalog of the Aggregate family: swap an aggregate call
  # along its SQL-meaningful ladder — `sum`↔`avg`, `min`↔`max` — wherever it appears inside a
  # query expression. An expression is an arbitrary shape (a bare call, a tuple, a list, a map, a
  # keyword list of them), so `swaps/1` walks the whole structure (`Mutare.Ecto.ExpressionWalk`)
  # and returns one *single-point* mutant per aggregate position — each the expression with
  # exactly one aggregate swapped.
  #
  # Callers feed it four positions: a `select`/`select_merge` value and an `order_by` value
  # (both whole-`from` and standalone/pipe — `Mutare.Ecto.Query`/`Mutare.Ecto.Clause`, delivered
  # in place), a `where`/`having` condition (`Mutare.Ecto.Host`, delivered `^`/`dynamic`-hosted
  # so a `having: sum(p.x) > n` swaps its aggregate behind the same selector as its operators),
  # and a free-standing `dynamic/1,2` condition (`Mutare.Ecto.Dynamic`, a whole-call rewrite
  # delivered in place).
  #
  # `count` is deliberately excluded (as in `Mutare.Ecto.RepoAggregate`): swapping it for a
  # value aggregate changes the result's meaning in a way its `:distinct`/arity contract makes
  # awkward, and `count`↔a-value-aggregate is rarely a focused, killable mutation.

  alias Mutare.Ecto.ExpressionWalk

  @agg_swaps %{sum: :avg, avg: :sum, min: :max, max: :min}
  @agg_funcs Map.keys(@agg_swaps)

  @doc """
  Every single-point aggregate swap of select-expression `expr` as `{:aggregate, node, label}`
  triples, or `[]` — the self-tagging `{family, node, label}` contract the other shared catalogs
  (`Mutare.Ecto.Fragment.mutants/2`, `Mutare.Ecto.Ordering.flips/1`) use, so a caller threads the
  family and finer label uniformly when it rebuilds the surrounding clause. `label` is the **source**
  function the swap mutates (`"sum"` for `sum`↔`avg`), so `# mutare:ignore[ecto:sum]` names just it.
  """
  @spec swaps(Macro.t()) :: [ExpressionWalk.tagged()]
  def swaps(expr), do: ExpressionWalk.walk(expr, &local/1)

  @doc false
  # The finer `# mutare:ignore` labels the aggregate family can emit — each swappable function name,
  # derived from the swap table so the vocabulary can't drift from what's produced. Folded into the
  # plugin's variant vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels, do: @agg_swaps |> Map.keys() |> Enum.map(&to_string/1)

  @doc """
  The SQL-meaningful swap of a single aggregate function name (`:sum`↔`:avg`, `:min`↔`:max`), or
  `nil` for a non-aggregate. Used by `Mutare.Ecto.RepoAggregate` to swap the *atom* form
  (`Repo.aggregate(q, :sum, …)`) against the same ladder this catalog swaps the *call* form along.
  """
  @spec swap(atom()) :: atom() | nil
  def swap(name), do: Map.get(@agg_swaps, name)

  # An aggregate call's own swap — a same-arity rename, so it always compiles. The function name is
  # the call form atom (not a wrapped literal), so the rename keeps the call's meta and renders
  # cleanly. Each mutant is tagged with the **source** function name (`"sum"`), the
  # `# mutare:ignore` label naming the swap; descent (a nested `max(sum(...))` — degenerate but
  # harmless) is the shared walker's job.
  defp local({f, meta, args}) when f in @agg_funcs and is_list(args),
    do: [{:aggregate, {@agg_swaps[f], meta, args}, to_string(f)}]

  defp local(_node), do: []
end
