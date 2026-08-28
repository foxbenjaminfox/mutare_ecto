defmodule Mutare.Ecto.Aggregate do
  @moduledoc false
  # The shared aggregate catalog of the Aggregate family: swap an aggregate call
  # along its SQL-meaningful ladder — `sum`↔`avg`, `min`↔`max` — wherever it appears inside a
  # query expression. An expression is an arbitrary shape (a bare call, a tuple, a list, a map, a
  # keyword list of them), so `swaps/1` walks the whole structure (`Mutare.Ecto.ExpressionWalk`)
  # and returns one *single-point* mutant per aggregate position — each the expression with
  # exactly one aggregate swapped.
  #
  # Two consumers, like `Mutare.Ecto.Scalar`: `Mutare.Ecto.Fragment` applies `local/1` per node in
  # a condition (a `having: sum(p.x) > n` swaps behind the same selector as its operators, or
  # inside the same whole-call `dynamic` rewrite — and never under `is_nil`, per `Fragment`'s
  # descent rule), and `swaps/1` walks a `select`/`select_merge`/`order_by` value
  # (`Mutare.Ecto.ExpressionWalk`) for the in-place deliveries (`Mutare.Ecto.Query`,
  # `Mutare.Ecto.Clause`).
  #
  # `count` is deliberately excluded — here and in `Mutare.Ecto.RepoAggregate`, which swaps the
  # atom form along this same ladder: it has a different arity/`:distinct` contract
  # (`aggregate(q, :count)`), so swapping it for a value aggregate changes the call's shape, not
  # just its meaning, and `count`↔a-value-aggregate is rarely a focused, killable mutation.
  #
  # **The ladder is Ecto's four `/1` aggregates and nothing else.** Every rung is
  # `Ecto.Query.API.sum/1`/`avg/1`/`min/1`/`max/1`, so the swap is only ever offered for an
  # arity-1 call that the resolve pass left *unstamped* — see the ownership rule on `local/2`.

  alias Mutare.Calls
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
  #
  # ## Only Ecto's own aggregate is on the ladder
  #
  # A name is not an identity: `sum`/`avg`/`min`/`max` are ordinary atoms an author's own query
  # macro (or `Kernel.min/2`) may wear, and a rename across the ladder is compile-safe *only*
  # between two calls Ecto actually defines. Renaming anything else emits a call that does not
  # exist — `avg(a, b)` — and Ecto's builder rejects it at expansion ("not a valid query
  # expression"), which fails the **whole** metamutant build rather than costing one mutant
  # (NOTES "Aggregate: only Ecto's own `/1` aggregate is on the ladder"). Two guards keep the
  # match to calls Ecto owns, and both are needed — an author macro may take any arity:
  #
  #   * **Arity** — every rung is `/1` (`Ecto.Query.API.sum/1` and friends), so a single argument
  #     is the shape. The sibling catalog guards its arities the same way and for the same reason
  #     (`Mutare.Ecto.Scalar.local/2`: binary arithmetic, `coalesce/2`).
  #   * **Unstamped** — Ecto's aggregates are plain `Ecto.Query.API` *functions*, never routed
  #     macros, so a resolve-pass macro stamp (`Mutare.Calls.macro_treatment/1`) proves the call
  #     belongs to a **registered author macro** whose grammar is its owner's, not this ladder's.
  #     This is the node-level twin of `Mutare.Ecto.Walk`'s author-macro rule, which governs only
  #     descent *into* such a call's arguments — the call node itself is still a position, so the
  #     name collision has to be refused here.
  defp local({f, meta, [_arg] = args} = node, _position) when f in @agg_funcs do
    if author_macro?(node),
      do: [],
      else: [Tag.new(:aggregate, {@agg_swaps[f], meta, args}, to_string(f))]
  end

  defp local(_node, _position), do: []

  # Stamped by the resolve pass as a registered macro call ⇒ an author's macro, not Ecto's
  # aggregate. `macro_treatment/1` is `nil` for every unregistered node, which is what a genuine
  # `sum(p.views)` is.
  defp author_macro?(node), do: Calls.macro_treatment(node) != nil
end
