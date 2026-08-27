defmodule Mutare.Ecto.ExpressionWalk do
  @moduledoc false
  # The **value-expression** rules over the plugin's one structural walk (`Mutare.Ecto.Walk`),
  # shared by the expression catalogs (`Mutare.Ecto.Aggregate`, `Mutare.Ecto.Scalar`): given an
  # arbitrary query-expression shape — a bare call, a tuple, a list, a map or keyword list of
  # them — and a `local` catalog producing the tagged alternatives of *one* node, `walk/3` returns
  # every **single-point** mutant: the whole expression with exactly one position replaced by one
  # of `local`'s alternatives, threading each mutant's family/label (`Mutare.Ecto.Tag`) up
  # unchanged while rebuilding its node.
  #
  # Two cross-cutting concerns live here, once, so every catalog gets them uniformly:
  #
  #   * **Node-level attribution.** Each mutant is stamped with
  #     `Mutare.Mutator.Mutation.at(node, mutant)` at the moment `local` offers it — the only
  #     point where the original node is still in hand (the walk rebuilds the surrounding form
  #     after) — so an in-place delivery (`Mutare.Ecto.Query`/`Mutare.Ecto.Clause`, which rebuild a
  #     whole clause or macro call around the mutant) reports the Site at the mutated
  #     expression's own range. That is what lets a line-scoped `# mutare:ignore` reach *one* of
  #     two same-family mutants sharing a clause: two identical `coalesce(a, b)`s in one `select`
  #     are indistinguishable by vocabulary — position is the only discriminator. On the hosted
  #     relay paths (`Mutare.Ecto.Host.Catalog`, `Mutare.Ecto.Subquery`) the stamp is structurally
  #     discarded — a hosted mutant is normalized to a `{node, note, variant, producer}` quad with
  #     no attribution slot — so the weave's own Site mechanics are untouched.
  #
  #   * **Ordering position.** The walk threads a `position` (`:value` | `:ordering`) down to the
  #     catalog, so a catalog can mark a mutant whose equivalence character changes in an ordering
  #     position (`Mutare.Ecto.Scalar`'s coalesce drop — dropping the fallback there exposes the
  #     engine's *default* NULL placement; see `Mutare.Ecto.Ordering` on why that default is
  #     engine-defined). Callers pass `:ordering` for an `order_by` value (the macros/keys
  #     carrying `Mutare.Ecto.Surface`'s `:ordering` capability); the rules here refine to
  #     `:ordering` inside the `order_by:` option of an `over/2` window — the one place an
  #     ordering hides *inside* another expression. (`over` is matched by call shape: it is not a
  #     routed macro, so there is no resolved identity to consult; a same-named user function
  #     would only refine a label/note, never change a mutant.)
  #
  # Descent is otherwise `Mutare.Ecto.Walk.structural/3`'s — a call's arguments under the shared
  # author-macro rule (a nested macro the author wrote may invent its own argument grammar, so an
  # argument is entered **only** when it is plainly standard syntax: a non-macro node or one the
  # macro routed `:expression` — e.g. a `select: clamp(sum(p.x), 10)` whose `clamp/2` is registered
  # `:skip` never has its `sum` swapped, because we don't know that `sum(p.x)` even means an
  # aggregate to `clamp`), a 2-tuple's sides (a `{a, b}` select, a keyword/map pair), a list's
  # elements; a `^` interpolation is never entered (its interior is ordinary Elixir — in these
  # in-place `select`/`order_by` walks it is left alone rather than wrongly mutated under an SQL
  # rationale).

  alias Mutare.Ecto.{AST, Tag, Walk}
  alias Mutare.Mutator.Mutation

  @typedoc "Where the walked expression sits: an ordinary value, or an ordering (sort-key) value."
  @type position :: :value | :ordering

  @typedoc "The per-node catalog: the tagged alternatives of one node at `position`, no descent."
  @type local :: (Macro.t(), position() -> [Tag.t()])

  @doc """
  Every single-point mutant of `expr` under the `local` per-node catalog, each stamped with
  node-level attribution (`Mutare.Mutator.Mutation.at/2`) so an in-place delivery reports it at
  the mutated node's own range. `position` is the root's position (`:ordering` for an `order_by`
  value); the walk refines it for the `order_by:` option of a nested `over/2` window.
  """
  @spec walk(Macro.t(), local(), position()) :: [Tag.t()]
  def walk(expr, local, position \\ :value),
    do: Walk.mutants(expr, position, &children/2, &anchored(local, &1, &2))

  # The node's own alternatives, each stamped with attribution at the node it replaces — the one
  # moment the original is still in hand (`Mutare.Ecto.Walk.mutants/4` rebuilds the surrounding
  # form afterwards, and `Tag.map_node/2` preserves the stamp on the way up). A catalog that set
  # its own attribution keeps it.
  defp anchored(local, node, position) do
    for tag <- local.(node, position),
        do: %{tag | attribution: tag.attribution || Mutation.at(node, tag.node)}
  end

  # An `over/2` window with written options (the idiomatic trailing keyword list): its
  # `order_by:` option value is an ordering position — the window's sort key — refined by
  # `window_option/1`. A bracketed-list options argument arrives `__block__`-wrapped and falls to
  # the structural rule: its mutants are still produced, only without the ordering refinement.
  defp children({:over, _meta, [_window_expr, options]} = node, position) when is_list(options),
    do: over_children(node, position)

  defp children({{:., _dot, [_receiver, :over]}, _meta, [_expr, options]} = node, position)
       when is_list(options),
       do: over_children(node, position)

  # Everything else descends structurally, each child inheriting the surrounding position.
  defp children(node, position), do: Walk.structural(node, position)

  # An `over/2` window's children: the window expression inherits the surrounding position (an
  # `over` can itself sit in an ordering value); each option's *value* is a child in the position
  # its key declares (the key names the option, and is never a position). `over` itself is a
  # position too, like any node (no catalog matches it today; the walk stays uniform).
  defp over_children({form, meta, [window_expr, options]}, position) do
    option_children =
      for {option, index} <- Enum.with_index(options) do
        {value, value_position, rewrap} = window_option(option)

        {value, value_position,
         &{form, meta, [window_expr, List.replace_at(options, index, rewrap.(&1))]}}
      end

    [{window_expr, position, &{form, meta, [&1, options]}} | option_children]
  end

  # One window option pair: the `order_by:` value is the window's sort key — an ordering
  # position — while `partition_by:`/`frame:` values are ordinary. A non-pair element (not
  # writable in Ecto's window grammar, but the rule stays total) is walked as a value.
  defp window_option({key, value}) do
    position = if AST.atom_value(key) == :order_by, do: :ordering, else: :value
    {value, position, &{key, &1}}
  end

  defp window_option(other), do: {other, :value, & &1}
end
