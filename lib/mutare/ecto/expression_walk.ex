defmodule Mutare.Ecto.ExpressionWalk do
  @moduledoc false
  # The shared structural walker under the expression catalogs (`Mutare.Ecto.Aggregate`,
  # `Mutare.Ecto.Scalar`): given an arbitrary query-expression shape — a bare call, a tuple, a
  # list, a map or keyword list of them — and a `local` catalog producing the tagged alternatives
  # of *one* node, `walk/3` returns every **single-point** mutant: the whole expression with
  # exactly one position replaced by one of `local`'s alternatives, threading each mutant's
  # family/label (`Mutare.Ecto.Tag`) up unchanged while rebuilding its node.
  #
  # Two cross-cutting concerns live here, once, so every catalog gets them uniformly:
  #
  #   * **Node-level attribution.** Each mutant is stamped with
  #     `Mutare.Mutator.Mutation.at(node, mutant)` at the moment `local` offers it — the only
  #     point where the original node is still in hand (every step above rebuilds the surrounding
  #     form) — so an in-place delivery (`Mutare.Ecto.Query`/`Mutare.Ecto.Clause`, which rebuild a
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
  #     carrying `Mutare.Ecto.Surface`'s `:ordering` capability); the walk itself refines to
  #     `:ordering` inside the `order_by:` option of an `over/2` window — the one place an
  #     ordering hides *inside* another expression. (`over` is matched by call shape: it is not a
  #     routed macro, so there is no resolved identity to consult; a same-named user function
  #     would only refine a label/note, never change a mutant.)
  #
  # Descent follows the same author-macro rule as `Mutare.Ecto.Fragment`, shared through
  # `Mutare.Ecto.Descent`: a nested macro the author wrote may invent its own argument grammar
  # (Mutare mutates source, not expansions), so a call's argument is descended **only** when it is
  # plainly standard syntax — a non-macro node or an argument the macro routed `:expression`.

  alias Mutare.Ecto.{AST, Descent, Tag}
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
  def walk(expr, local, position \\ :value)

  # An interpolation island (`^expr`) is ordinary Elixir evaluated at runtime — outside every SQL
  # catalog's competence, so never offered and never descended. (In a hosted condition the host
  # sub-contracts the interior to core's generation; in these in-place `select`/`order_by` walks
  # the interior is left alone rather than wrongly mutated under an SQL rationale.)
  def walk({:^, _meta, _args}, _local, _position), do: []

  # An `over/2` window with written options (the idiomatic trailing keyword list): its
  # `order_by:` option value is an ordering position — the window's sort key — refined by
  # `window_option/2`. A bracketed-list options argument arrives `__block__`-wrapped and falls to
  # the generic clause: its mutants are still produced, only without the ordering refinement.
  def walk({:over, _meta, [_window_expr, options]} = node, local, position)
      when is_list(options),
      do: over_mutants(node, local, position)

  def walk({{:., _dot, [_receiver, :over]}, _meta, [_expr, options]} = node, local, position)
      when is_list(options),
      do: over_mutants(node, local, position)

  # A call/operator node (atom form or a remote `{:., …}` form): offer the node's own alternatives,
  # then descend into its arguments so a nested position is reached too.
  def walk({form, meta, args} = node, local, position) when is_list(args) do
    # mutare:ignore[operand_swap] local/descend order is irrelevant — mutants are consumed as a set
    offer(local, node, position) ++ lift_args(form, meta, args, local, position)
  end

  # A 2-tuple literal — a `{a, b}` select, or a keyword/map pair: descend into both sides.
  def walk({left, right}, local, position) do
    # mutare:ignore[operand_swap] branch order is irrelevant — mutants are consumed as a set
    for(tag <- walk(left, local, position), do: Tag.map_node(tag, &{&1, right})) ++
      for(tag <- walk(right, local, position), do: Tag.map_node(tag, &{left, &1}))
  end

  # A list — a list select, the args of a `%{}`/`{}` node, or a keyword list: descend per element.
  def walk(list, local, position) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, i} ->
      for tag <- walk(el, local, position), do: Tag.map_node(tag, &List.replace_at(list, i, &1))
    end)
  end

  # Atoms, literals, variables, field references: nothing to offer, nothing to descend.
  def walk(_node, _local, _position), do: []

  # The node's own alternatives, each stamped with attribution at the node it replaces — the one
  # moment the original is still in hand. `Tag.map_node/2` preserves the stamp on the way up. A
  # catalog that set its own attribution keeps it.
  defp offer(local, node, position) do
    for tag <- local.(node, position),
        do: %{tag | attribution: tag.attribution || Mutation.at(node, tag.node)}
  end

  # Descend into a call/operator's arguments, but only where the argument is plainly standard
  # syntax we can mutate (`Mutare.Ecto.Descent`) — e.g. a `select: clamp(sum(p.x), 10)` whose
  # `clamp/2` is registered `:skip` never has its `sum` swapped, because we don't know that
  # `sum(p.x)` even means an aggregate to `clamp`.
  defp lift_args(form, meta, args, local, position) do
    Descent.each_arg({form, meta, args}, fn arg, i ->
      for tag <- walk(arg, local, position),
          do: Tag.map_node(tag, &{form, meta, List.replace_at(args, i, &1)})
    end)
  end

  # An `over/2` window's mutants: the window expression inherits the surrounding position (an
  # `over` can itself sit in an ordering value); each option value is walked in the position its
  # key declares. `over` itself is offered too (no catalog matches it today; the walk stays
  # uniform).
  defp over_mutants({form, meta, [window_expr, options]} = node, local, position) do
    # mutare:ignore[operand_swap] group order is irrelevant — mutants are consumed as a set
    offer(local, node, position) ++
      for(
        tag <- walk(window_expr, local, position),
        do: Tag.map_node(tag, &{form, meta, [&1, options]})
      ) ++
      (options
       |> Enum.with_index()
       |> Enum.flat_map(fn {option, i} ->
         for tag <- window_option(option, local),
             do: Tag.map_node(tag, &{form, meta, [window_expr, List.replace_at(options, i, &1)]})
       end))
  end

  # One window option pair: the `order_by:` value is the window's sort key — an ordering
  # position — while `partition_by:`/`frame:` values are ordinary. A non-pair element (not
  # writable in Ecto's window grammar, but the walk stays total) is walked as a value.
  defp window_option({key, value}, local) do
    position = if AST.atom_value(key) == :order_by, do: :ordering, else: :value
    for tag <- walk(value, local, position), do: Tag.map_node(tag, &{key, &1})
  end

  defp window_option(other, local), do: walk(other, local, :value)
end
