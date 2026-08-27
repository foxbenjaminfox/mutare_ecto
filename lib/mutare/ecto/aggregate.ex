defmodule Mutare.Ecto.Aggregate do
  @moduledoc false
  # The shared aggregate catalog of the Aggregate family: swap an aggregate call
  # along its SQL-meaningful ladder — `sum`↔`avg`, `min`↔`max` — wherever it appears inside a
  # query expression. An expression is an arbitrary shape (a bare call, a tuple, a list, a map, a
  # keyword list of them), so `swaps/1` walks the whole structure (`Mutare.Ecto.ExpressionWalk`)
  # and returns one *single-point* mutant per aggregate position — each the expression with
  # exactly one aggregate swapped.
  #
  # Two consumers, mirroring `Mutare.Ecto.Scalar`'s split:
  #
  #   * a `where`/`having` condition — hosted, or the body of a free-standing `dynamic/1,2` —
  #     `Mutare.Ecto.Fragment` applies `local/1` per node as it walks the condition, so a
  #     `having: sum(p.x) > n` swaps its aggregate behind the same selector as its operators
  #     (`Mutare.Ecto.Host`), or inside the same whole-call rewrite (`Mutare.Ecto.Dynamic`) — and
  #     never under `is_nil`, where a swap preserves NULL-ness;
  #   * a `select`/`select_merge`/`order_by` value — `swaps/1` walks the whole expression
  #     (`Mutare.Ecto.ExpressionWalk`) and each swap is delivered **in place**
  #     (`Mutare.Ecto.Query` for the `from` keyword clauses, `Mutare.Ecto.Clause` for the
  #     standalone/pipe macros).
  #
  # `count` is deliberately excluded (as in `Mutare.Ecto.RepoAggregate`): swapping it for a
  # value aggregate changes the result's meaning in a way its `:distinct`/arity contract makes
  # awkward, and `count`↔a-value-aggregate is rarely a focused, killable mutation.

  alias Mutare.Ecto.{ExpressionWalk, Tag}

  @behaviour Mutare.Ecto.Vocabulary

  @agg_swaps %{sum: :avg, avg: :sum, min: :max, max: :min}
  @agg_funcs Map.keys(@agg_swaps)

  @doc """
  Every single-point aggregate swap of select-expression `expr` as `:aggregate`-family
  `Mutare.Ecto.Tag`s, or `[]` — the self-tagging contract the other shared catalogs
  (`Mutare.Ecto.Fragment.mutants/2`, `Mutare.Ecto.Ordering.flips/1`) use, so a caller threads the
  family and finer label uniformly when it rebuilds the surrounding clause. The label is the
  **source** function the swap mutates (`"sum"` for `sum`↔`avg`), so `# mutare:ignore[ecto:sum]`
  names just it.
  """
  @spec swaps(Macro.t()) :: [Tag.t()]
  def swaps(expr), do: ExpressionWalk.walk(expr, &local/2)

  # `Mutare.Ecto.Vocabulary`: each swappable function name — the **source** label `local/2` tags.
  @impl Mutare.Ecto.Vocabulary
  def variant_labels, do: Enum.map(@agg_funcs, &to_string/1)

  @doc """
  The SQL-meaningful swap of a single aggregate function name (`:sum`↔`:avg`, `:min`↔`:max`), or
  `nil` for a non-aggregate. Used by `Mutare.Ecto.RepoAggregate` to swap the *atom* form
  (`Repo.aggregate(q, :sum, …)`) against the same ladder this catalog swaps the *call* form along.
  """
  @spec swap(atom()) :: atom() | nil
  def swap(name), do: Map.get(@agg_swaps, name)

  @doc """
  The aggregate swap of one node — **no descent** — the per-node hook `Mutare.Ecto.Fragment`
  applies as it walks a condition (its own traversal already handles descent; a condition is a
  `:value` position by construction).
  """
  @spec local(Macro.t()) :: [Tag.t()]
  def local(node), do: local(node, :value)

  # An aggregate call's own swap — a same-arity rename, so it always compiles. The function name is
  # the call form atom (not a wrapped literal), so the rename keeps the call's meta and renders
  # cleanly. Each mutant is tagged with the **source** function name (`"sum"`), the
  # `# mutare:ignore` label naming the swap; descent (a nested `max(sum(...))` — degenerate but
  # harmless) is the shared walker's job. The walk's position is ignored: an aggregate swap means
  # the same thing in a `select` value and an ordering.
  defp local({f, meta, args}, _position) when f in @agg_funcs and is_list(args),
    do: [Tag.new(:aggregate, {@agg_swaps[f], meta, args}, to_string(f))]

  defp local(_node, _position), do: []
end
