defmodule Mutare.Ecto.Walk do
  @moduledoc false
  # The **one** structural walk under every catalog in the plugin — the SQL condition catalog
  # (`Mutare.Ecto.Fragment`: its mutation catalog *and* its island collection) and the
  # value-expression catalogs (`Mutare.Ecto.Aggregate`/`Scalar`, through
  # `Mutare.Ecto.ExpressionWalk`).
  #
  # `positions/3` visits every node a `children` rule admits — **once** — and yields each as
  # `{node, ctx, rebuild}`: the node, the context its owner threaded down to it, and a function
  # that reconstructs the walked **root** around a replacement for exactly that node. A catalog
  # is then a per-node *reader* of those positions (`mutants/4`: the node's own alternatives,
  # each rebuilt into the root), and a second reader of the same positions
  # (`Mutare.Ecto.Fragment.islands/1`) agrees with the first about which nodes exist **by
  # construction** — there is no second traversal to drift. Before this module, the condition
  # catalog's mutation walk and its island walk were two hand-rolled copies of one traversal,
  # and the select/order_by walker a third.
  #
  # `structural/3` is the default `children` rule — a call's arguments under the author-macro
  # rule below, a written list's elements, a 2-tuple's sides — and a `^` pin is a leaf for every
  # SQL-side walk (its interior is ordinary Elixir, never SQL for a catalog to reason about; the
  # condition catalog's `islands/1` hands it to core instead). A catalog's own rule wraps it to
  # claim a **unit** (a whole subtree whose inner nodes are not positions — `Fragment`'s
  # `not is_nil(x)`), to refuse a shape it does not speak, or to refine a child's context
  # (`ExpressionWalk`'s `order_by:` option of an `over/2` window). A rule can only ever
  # *narrow* what a reader sees: readers never descend on their own.
  #
  # ## The author-macro rule
  #
  # A nested macro the author wrote may invent its own argument grammar — Mutare mutates source,
  # not expansions, and a macro is free to accept arguments that are valid Elixir *tokens* but not
  # standard Ecto syntax. So a call's argument is descended **only** when it is plainly standard
  # syntax: a non-macro node (`nil` routing — an ordinary operator/call/field we own), or an
  # argument the macro routed `:expression` (the one treatment that asserts "a standard expression
  # here, mutate it"). Every other treatment — `:skip`, `:pattern`, `:binding_pattern`, `:hosted`,
  # `:interpolated`, `{:keyword, …}` — marks an argument whose grammar is the macro's own, left raw.
  # The per-argument routing is read from the resolve-pass stamp via `Mutare.Calls.macro_treatment/1`.

  alias Mutare.Calls
  alias Mutare.Ecto.Tag

  @typedoc "Reconstructs the walked root (or, for a child, its parent) around a replacement node."
  @type rebuild :: (Macro.t() -> Macro.t())

  @typedoc "One admitted node: the node, its context, and the rebuild of the root around it."
  @type position(ctx) :: {Macro.t(), ctx, rebuild()}

  @typedoc "One admitted child of a node: the child, its context, and its splice back into the parent."
  @type child(ctx) :: {Macro.t(), ctx, rebuild()}

  @typedoc "The descent rule: the children the walk continues into from one node under its context."
  @type children(ctx) :: (Macro.t(), ctx -> [child(ctx)])

  @typedoc "A child's context, from its parent node, its index in the parent, and the parent's context."
  @type child_ctx(ctx) :: (Macro.t(), non_neg_integer(), ctx -> ctx)

  @typedoc "The per-node catalog: the tagged alternatives of one node at its context, no descent."
  @type local(ctx) :: (Macro.t(), ctx -> [Tag.t()])

  @doc """
  Every node of `root` the `children` rule admits, in pre-order (a node before its subtree), as
  `{node, ctx, rebuild}` — `rebuild.(replacement)` is the whole `root` with exactly that node
  replaced. The root itself is the first position (its rebuild is the identity), under `ctx`.
  """
  @spec positions(Macro.t(), ctx, children(ctx)) :: [position(ctx)] when ctx: var
  def positions(root, ctx, children), do: walk(root, ctx, & &1, children)

  defp walk(node, ctx, rebuild, children) do
    descendants =
      for {child, child_ctx, splice} <- children.(node, ctx),
          position <- walk(child, child_ctx, &rebuild.(splice.(&1)), children),
          do: position

    [{node, ctx, rebuild} | descendants]
  end

  @doc """
  Every **single-point** mutant of `root` under the `local` per-node catalog: for each position
  the `children` rule admits, each of `local`'s alternatives for that one node, rebuilt into the
  whole `root` with its family/label (`Mutare.Ecto.Tag`) carried up unchanged.
  """
  @spec mutants(Macro.t(), ctx, children(ctx), local(ctx)) :: [Tag.t()] when ctx: var
  def mutants(root, ctx, children, local) do
    for {node, node_ctx, rebuild} <- positions(root, ctx, children),
        tag <- local.(node, node_ctx),
        do: Tag.map_node(tag, rebuild)
  end

  @doc """
  The default descent: a call's arguments (only those the author-macro rule admits), a
  2-tuple's two sides, a written list's elements — each with the context `child_ctx` derives for
  it (inheriting the parent's by default) and the splice that puts a replacement back into the
  parent. A `^` pin and every other node (a variable, a bare scalar, a field reference) is a leaf.
  """
  @spec structural(Macro.t(), ctx, child_ctx(ctx)) :: [child(ctx)] when ctx: var
  def structural(node, ctx, child_ctx \\ &inherit/3)

  def structural({:^, _meta, _args}, _ctx, _child_ctx), do: []

  def structural({form, meta, args} = node, ctx, child_ctx) when is_list(args) do
    routing = Calls.macro_treatment(node)

    for {arg, index} <- Enum.with_index(args),
        descend_arg?(routing, index),
        do: {arg, child_ctx.(node, index, ctx), &{form, meta, List.replace_at(args, index, &1)}}
  end

  def structural({left, right} = node, ctx, child_ctx) do
    [
      {left, child_ctx.(node, 0, ctx), &{&1, right}},
      {right, child_ctx.(node, 1, ctx), &{left, &1}}
    ]
  end

  def structural(list, ctx, child_ctx) when is_list(list) do
    for {element, index} <- Enum.with_index(list),
        do: {element, child_ctx.(list, index, ctx), &List.replace_at(list, index, &1)}
  end

  def structural(_leaf, _ctx, _child_ctx), do: []

  defp inherit(_parent, _index, ctx), do: ctx

  defp descend_arg?(nil, _index), do: true
  defp descend_arg?(routing, index), do: Enum.at(routing, index) == :expression
end
