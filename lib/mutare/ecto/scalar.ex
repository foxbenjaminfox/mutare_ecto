defmodule Mutare.Ecto.Scalar do
  @moduledoc false
  # The shared **scalar-expression** catalog: mutations of value-computing forms that may
  # appear in *any* query expression, not only a boolean condition —
  #
  #   * **Arithmetic** — `+`↔`-`, `*`↔`/`, paired by identity: 0 for the additive pair, 1 for
  #     the multiplicative;
  #   * **Coalesce** — `coalesce(x, default)` → `x`, dropping the NULL fallback ("does any test
  #     exercise the row where the default kicks in?"). The one catalog mutation that *changes*
  #     an expression's NULL-ness — that is its entire point: the two forms differ exactly on the
  #     rows where `x` is NULL, so its survivors carry a NULL-data equivalence note.
  #
  # Two consumers, like `Mutare.Ecto.Aggregate`: `Mutare.Ecto.Fragment` applies `local/2` per node
  # in a hosted condition (delivered alongside the operator swaps), and `swaps/2` walks a
  # `select`/`select_merge`/`order_by` value (`Mutare.Ecto.ExpressionWalk`) for the in-place
  # deliveries (`Mutare.Ecto.Query`, `Mutare.Ecto.Clause`).
  #
  # SQL-owned (see `Mutare.Ecto.Fragment`): a NULL operand makes every arm NULL, and `/` is the
  # *database's* division — integer truncation and the zero divisor are the engine's behaviour
  # (NULL on SQLite and MySQL, an error on Postgres), not Elixir's float `//2`. So `+`↔`-`
  # changes a row's computed value and never its NULL-ness, while `*`↔`/` can change both
  # (what `Fragment` relies on beneath `is_nil`). **Binary** forms only: a written negative
  # number parses as the arity-1 `-` over the wrapped literal — sign syntax, not an operator to
  # swap.

  alias Mutare.Ecto.{ExpressionWalk, Tag, Walk}

  @behaviour Mutare.Ecto.Vocabulary

  @arithmetic_swaps %{:+ => :-, :- => :+, :* => :/, :/ => :*}

  # The ordering-position coalesce drop's finer label, named apart from the plain "coalesce"
  # because its equivalence turns on the engine's default NULL placement (see
  # `Mutare.Ecto.Ordering`): the distinct label lets `Mutare.Ecto.Equivalence.note/2` attach the
  # placement-aware note, and lets `# mutare:ignore[ecto:coalesce_in_ordering]` name exactly the
  # ordering-position drop — while a family-level `[ecto:coalesce]` still covers both.
  @ordering_coalesce_label "coalesce_in_ordering"

  @doc """
  Every single-point scalar mutant of expression `expr` as self-tagging `Mutare.Ecto.Tag`s — the
  contract the other shared catalogs (`Mutare.Ecto.Aggregate.swaps/1`,
  `Mutare.Ecto.Ordering.flips/1`) use. The label is the **source** operator the swap mutates
  (`"+"` for `+`↔`-`), so `# mutare:ignore[ecto:+]` names just it. `position` is the expression's
  root position (`:ordering` for an `order_by` value — `Mutare.Ecto.ExpressionWalk.position/0`);
  a coalesce drop there is labelled `"coalesce_in_ordering"`.
  """
  @spec swaps(Macro.t(), ExpressionWalk.position(), Mutare.Ecto.Walk.slot()) :: [Tag.t()]
  def swaps(expr, position \\ :value, root_slot \\ nil),
    do: ExpressionWalk.walk(expr, &local/2, position, root_slot)

  @doc """
  The scalar mutants of one node — **no descent** — at its `t:Mutare.Ecto.ExpressionWalk.ctx/0`:
  the per-node hook `swaps/2` threads through the walk, and the one `Mutare.Ecto.Fragment`
  applies as it walks a hosted condition (its own traversal already handles descent; a boolean
  condition is a `:value` position by construction). The two-element args pattern is the
  binary-arity guard: a written `-5` is the arity-1 `-` over the wrapped literal, sign syntax
  with no swap (and Ecto has no unary `+`); `coalesce` is exactly `/2` in Ecto, so an off-arity
  call is left alone. Only the coalesce drop reads the context — the position for its label, the
  slot for its grammar guard; an arithmetic swap keeps the operator's kind and means the same
  thing everywhere.
  """
  @spec local(Macro.t(), ExpressionWalk.ctx()) :: [Tag.t()]
  def local({form, meta, [_l, _r] = args}, _ctx) when is_map_key(@arithmetic_swaps, form),
    do: [Tag.new(:arithmetic, {@arithmetic_swaps[form], meta, args}, to_string(form))]

  # The coalesce drop replaces the whole call with its wrapped expression. The SQL type stays
  # the same, and only the rows where `x` is NULL change. The *default*'s own value mutants are
  # the traversal's job (it is an ordinary data argument).
  def local({:coalesce, _meta, [x, _default]}, {position, slot}) do
    if fits?(x, slot),
      do: [Tag.new(:coalesce, x, coalesce_label(position))],
      else: []
  end

  def local(_node, _ctx), do: []

  # ## The drop must fit its parent's grammar
  #
  # A `coalesce` call is a valid operand wherever Ecto accepts an expression, but the drop
  # replaces it with `x`, which is a different kind of expression. Some slots restrict what they
  # accept:
  #
  #   * a comparison operand may not be a literal `nil` ("comparison with nil is forbidden"), so
  #     `coalesce(nil, p.v) > 0` has no `nil > 0` drop. A keyword-filter pair value is such an
  #     operand too, because Ecto builds `field == value` from the pair, and its caller says so
  #     (`Mutare.Ecto.Subquery`);
  #   * `type/2`'s first argument must be one of the forms its builder lists (`Mutare.Ecto.Walk.typable?/1`), so
  #     `type(coalesce(p.v > 0, false), :boolean)` has no `type(p.v > 0, :boolean)` drop;
  #   * a pin standing as a whole clause expression (`select: ^fields`), as an `order_by`
  #     entry (`[asc: ^field]`), or as a window option entry (`partition_by: ^fields`) names
  #     fields or dynamics rather than a value. So `select: coalesce(^override, count(r.id))`
  #     has no `select: ^override` drop.
  #
  # Ecto rejects a violation when it expands the macro (which fails the whole metamutant build)
  # or when it builds the query. The drop is withheld in those slots, because no written form
  # there says "NULL where the fallback was". Ecto's other operand slots (probed on 3.14) accept
  # whatever a `coalesce` argument can be. The slot reads through tuples and lists, so an
  # element of a compared tuple counts as the comparison's operand, and an element of a `select`
  # tuple counts as the `select` root. That withholds drops Ecto would accept
  # (`{coalesce(nil, a), b} > t`, `select: {coalesce(^x, 0), p.id}`), a conservative loss.
  @comparisons [:==, :!=, :<, :>, :<=, :>=]
  @pin_naming_clauses [:select, :select_merge, :order_by, :prepend_order_by]

  defp fits?(x, {comparison, 2, _index}) when comparison in @comparisons, do: not nil_literal?(x)
  defp fits?(x, {:type, 2, 0}), do: Walk.typable?(x)
  defp fits?(x, {clause, 3, 2}) when clause in @pin_naming_clauses, do: not pin?(x)
  defp fits?(x, {:over, 2, 1}), do: not pin?(x)
  defp fits?(_x, _slot), do: true

  defp pin?(node), do: match?({:^, _meta, [_interior]}, node)

  defp nil_literal?({:__block__, _meta, [nil]}), do: true
  defp nil_literal?(node), do: is_nil(node)

  # `Mutare.Ecto.Vocabulary`: each swappable operator plus the coalesce drop's two positional
  # labels.
  @impl Mutare.Ecto.Vocabulary
  def variant_labels do
    operators = @arithmetic_swaps |> Map.keys() |> Enum.map(&to_string/1)
    operators ++ [coalesce_label(:value), coalesce_label(:ordering)]
  end

  defp coalesce_label(:ordering), do: @ordering_coalesce_label
  defp coalesce_label(:value), do: "coalesce"
end
