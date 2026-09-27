defmodule Mutare.Ecto.ExpressionWalk do
  @moduledoc false
  # The **value-expression** rules over the plugin's one structural walk (`Mutare.Ecto.Walk`),
  # shared by the expression catalogs (`Mutare.Ecto.Aggregate`, `Mutare.Ecto.Scalar`): given an
  # arbitrary query-expression shape — a bare call, a tuple, a list, a map or keyword list of
  # them — and a `local` catalog producing the tagged alternatives of *one* node, `walk/3` returns
  # every **single-point** mutant, each anchored at the node it replaces
  # (`Mutare.Ecto.Walk.mutants/4`).
  #
  # The one concern that lives here is the **ordering position**: the walk threads a `position`
  # (`:value` | `:ordering`) down to the catalog, so a catalog can mark a mutant whose
  # equivalence character changes in an ordering position (`Mutare.Ecto.Scalar`'s coalesce drop —
  # see `Mutare.Ecto.Ordering` on the engine-default NULL placement it exposes). Callers pass
  # `:ordering` for an `order_by` value (`Mutare.Ecto.ValueCatalog.position/1`); the rules here
  # refine to `:ordering` inside the `order_by:` option of an `over/2` window — the one place an
  # ordering hides *inside* another expression. (`over` is matched by call shape: it is not a
  # routed macro, so there is no resolved identity to consult; a same-named user function would
  # only refine a label/note, never change a mutant.)
  #
  # Alongside the position, each node carries its `Mutare.Ecto.Walk.slot/0` — the call argument it
  # fills — so a catalog whose mutant changes the node's syntactic kind can check what the
  # parent accepts there (`Mutare.Ecto.Scalar`'s coalesce drop).
  #
  # Descent is otherwise `Mutare.Ecto.Walk.structural/3`'s — a call's arguments under the
  # author-macro rule, a 2-tuple's sides (a `{a, b}` select, a keyword/map pair), a list's
  # elements; a `^` pin is a leaf (its interior is ordinary Elixir, left to core).

  alias Mutare.Ecto.{Tag, Walk, Window}

  @typedoc "Where the walked expression sits: an ordinary value, or an ordering (sort-key) value."
  @type position :: :value | :ordering

  @typedoc "What the walk threads to each node: its position and the call argument it fills."
  @type ctx :: {position(), Walk.slot()}

  @typedoc "The per-node catalog: the tagged alternatives of one node at its `ctx`, no descent."
  @type local :: (Macro.t(), ctx() -> [Tag.t()])

  @doc """
  Every single-point mutant of `expr` under the `local` per-node catalog, each anchored at the
  node it replaces (`Mutare.Ecto.Walk.mutants/4`). `position` is the root's position
  (`:ordering` for an `order_by` value); the walk refines it for the `order_by:` option of a
  nested `over/2` window.
  """
  @spec walk(Macro.t(), local(), position()) :: [Tag.t()]
  def walk(expr, local, position \\ :value),
    do: Walk.mutants(expr, {position, nil}, &children/2, local)

  # An `over/2` window with written options — the idiomatic trailing keyword list, or the same
  # list written in brackets (`over(x, [order_by: …])`, which Sourceror wraps in a `__block__`;
  # `AST.unwrap_list/1` reads through either spelling): its `order_by:` option value is an
  # ordering position — the window's sort key — refined by `Mutare.Ecto.Window`.
  defp children({:over, _meta, [_window_expr, _options]} = node, ctx),
    do: over_children(node, ctx)

  defp children({{:., _dot, [_receiver, :over]}, _meta, [_expr, _options]} = node, ctx),
    do: over_children(node, ctx)

  # Everything else descends structurally, each child inheriting the surrounding position.
  defp children(node, ctx), do: Walk.structural(node, ctx, &child_ctx/3)

  # A window option's value is no call argument Ecto restricts, so it fills no slot.
  defp over_children(node, ctx) do
    if Mutare.Calls.routed_treatments(node) == nil do
      Window.children(node, ctx, fn
        :ordering, _ctx -> {:ordering, nil}
        _role, {position, _slot} -> {position, nil}
      end)
    else
      Walk.structural(node, ctx, &child_ctx/3)
    end
  end

  defp child_ctx(parent, index, {position, slot}),
    do: {position, Walk.child_slot(parent, index, slot)}
end
