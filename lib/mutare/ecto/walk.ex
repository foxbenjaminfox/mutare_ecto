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
  # (`Mutare.Ecto.Fragment.islands/2`) agrees with the first about which nodes exist **by
  # construction** — there is no second traversal to drift (NOTES "Walk: one traversal under
  # every catalog").
  #
  # `structural/3` is the default `children` rule — a call's arguments under the author-macro
  # rule below, a written list's elements, a 2-tuple's sides — and a `^` pin is a leaf for every
  # SQL-side walk (its interior is sub-contracted to core — see `Mutare.Ecto.Island`). A
  # catalog's own rule wraps it to claim a **unit** (a whole subtree whose inner nodes are not
  # positions — `Fragment`'s `exists(subquery)`), to refuse a shape it does not speak, or to
  # refine a child's context (`ExpressionWalk`'s `order_by:` option of an `over/2` window;
  # `Fragment`'s NULL-ness-only observation beneath `is_nil`). A rule can only ever *narrow*
  # what a reader sees: readers never descend on their own.
  #
  # ## Node-level attribution
  #
  # Every mutant `mutants/4` yields is stamped with **node-level attribution**
  # (`Mutare.Mutator.Mutation.at/2`) at the node it replaces, so an in-place delivery
  # (`Mutare.Ecto.Query`/`Mutare.Ecto.Clause`, which rebuild a whole clause or macro call around
  # the mutant; `Mutare.Ecto.Dynamic`, which rebuilds the whole `dynamic` call) reports the Site at
  # the mutated expression's own range. That is what lets a line-scoped `# mutare:ignore` reach
  # *one* of two same-family mutants sharing a clause: two identical `coalesce(a, b)`s in one
  # `select`, or the two comparisons of a multi-line `dynamic`, are indistinguishable by
  # vocabulary — position is the only discriminator. A tag a catalog already attributed (a
  # subquery interior mutant, anchored where the interior catalog produced it) keeps its own. On
  # the hosted relay paths (`Mutare.Ecto.Island`, `Mutare.Ecto.Subquery`) core preserves the
  # same stamp, so both delivery paths report the logical change at its original location.
  #
  # ## The author-macro rule
  #
  # A nested macro the author wrote may invent its own argument grammar — Mutare mutates source,
  # not expansions, and a macro is free to accept arguments that are valid Elixir *tokens* but not
  # standard Ecto syntax. So a call's argument is descended **only** when it is plainly standard
  # syntax: a non-macro node (`nil` routing — an ordinary operator/call/field we own), or an
  # argument the macro routed `:expression` (the one treatment that asserts "a standard expression
  # here, mutate it"). Every other treatment — `:raw`, `:pattern`, `:binding_pattern`, `:hosted`,
  # `:interpolated`, `{:keyword, …}` — marks an argument whose grammar is the macro's own, left raw
  # (e.g. a `select: clamp(sum(p.x), 10)` whose `clamp/2` is registered `:raw` never has its
  # `sum` swapped: nothing says `sum(p.x)` even means an aggregate to `clamp`). The per-argument
  # routing is read from the resolve-pass stamp via `Mutare.Calls.routed_treatments/1`. Every
  # catalog (`Fragment`'s `mutants`/`islands`, `ExpressionWalk`) is a reader over this walk and
  # never descends on its own, so the rule is applied in exactly one place.
  #
  # Query-building macros are a separate boundary: their `:expression` source computes a query
  # in Elixir, not an SQL value. Their arguments and a query pipe's left side stay out of this
  # walk. Subquery reads their SQL clauses explicitly and hands computed sources to core.

  alias Mutare.Calls
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Ecto.Tag
  alias Mutare.Mutator.Mutation

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

  @typedoc """
  The call argument a node fills, as `{parent_form, arity, index}` — or `nil` for the walked
  root. The key both catalogs read a parent's grammar by (`Mutare.Ecto.Fragment`'s
  structural-position registry, `Mutare.Ecto.Scalar`'s coalesce-drop guard).
  """
  @type slot :: {term(), non_neg_integer(), non_neg_integer()} | nil

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
  whole `root` with its family/label (`Mutare.Ecto.Tag`) carried up unchanged — and **anchored**
  at the node it replaces (see "Node-level attribution" in the module comment).
  """
  @spec mutants(Macro.t(), ctx, children(ctx), local(ctx)) :: [Tag.t()] when ctx: var
  def mutants(root, ctx, children, local) do
    for {node, node_ctx, rebuild} <- positions(root, ctx, children),
        tag <- local.(node, node_ctx),
        do: tag |> anchor(node) |> Tag.map_node(rebuild)
  end

  # The stamp happens here — the one moment the original node is still in hand (the rebuild
  # reconstructs the surrounding form right after; `Tag.map_node/2` preserves the stamp on the
  # way up).
  defp anchor(%Tag{attribution: nil, node: mutant} = tag, node),
    do: %{tag | attribution: Mutation.at(node, mutant)}

  defp anchor(tag, _node), do: tag

  # The calls Ecto's query builder reads itself, by name **and arity**: the builder dispatches on
  # both before it tries a macro expansion, so an author's `coalesce/1` or `sum/2` is expanded
  # while a same-arity `sum/1` never is. They are `Ecto.Query.API`'s and `Ecto.Query.WindowAPI`'s
  # functions (read from the Ecto this is compiled against), the arities the builder accepts
  # beyond those (`over/1`, `filter/1`, a unary `-`, `subquery/1`, `literal/1`, the older name of
  # `identifier/1`), and the syntax forms it escapes, a field access's inner `.` node included
  # (a prewalk visits it). `fragment/n` and the collection forms take any arity.
  @ecto_calls MapSet.new(
                Ecto.Query.API.__info__(:functions) ++
                  Ecto.Query.WindowAPI.__info__(:functions) ++
                  [over: 1, filter: 1, -: 1, subquery: 1, literal: 1, ^: 1, .: 2, %: 2, |: 2] ++
                  [sigil_s: 2, sigil_S: 2, sigil_w: 2, sigil_W: 2]
              )
  @any_arity [:fragment, :{}, :%{}, :<<>>, :__block__, :__aliases__]

  @doc """
  Whether Ecto may expand `node` into query syntax that the written source does not show: a
  registered author macro, a module attribute, a remote call, or any other local call outside
  Ecto's own query vocabulary (by name and arity), which Ecto can only be expanding as a macro. A field access
  (`p.x`, `as(:p).x`) and a JSON path (`p.meta["k"]`) are not calls in this sense.

  The descent itself does not ask this (an unregistered call is still read as standard syntax,
  the author-macro rule above). A reader that *concludes* something from what it did not see —
  that a clause reads no projection, that a condition is not the literal `true` — asks it, so an
  unseen expansion counts as unknown rather than as absent.
  """
  @spec opaque_call?(Macro.t()) :: boolean()
  def opaque_call?({:@, _meta, [_attribute]}), do: true
  def opaque_call?({{:., _, [Access, :get]}, _meta, _args}), do: false

  def opaque_call?({{:., _, [receiver, _name]}, _meta, args} = node) when is_list(args),
    do: remote?(receiver) or Calls.routed_treatments(node) != nil

  def opaque_call?({name, _meta, args} = node) when is_atom(name) and is_list(args),
    do: not ecto_call?(name, length(args)) or Calls.routed_treatments(node) != nil

  def opaque_call?(_node), do: false

  defp ecto_call?(name, _arity) when name in @any_arity, do: true
  defp ecto_call?(name, arity), do: MapSet.member?(@ecto_calls, {name, arity})

  defp remote?({:__aliases__, _meta, _segments}), do: true
  defp remote?(module), do: is_atom(module)

  @doc """
  The default descent: a call's arguments (only those the author-macro rule admits), a
  2-tuple's two sides, a written list's elements — each with the context `child_ctx` derives for
  it (inheriting the parent's by default) and the splice that puts a replacement back into the
  parent. A `^` pin and every other node (a variable, a bare scalar, a field reference) is a leaf.
  """
  @spec structural(Macro.t(), ctx, child_ctx(ctx)) :: [child(ctx)] when ctx: var
  def structural(node, ctx, child_ctx \\ &inherit/3)

  def structural({:^, _meta, _args}, _ctx, _child_ctx), do: []

  def structural({:|>, _meta, [_left, right]} = node, ctx, child_ctx) do
    if QueryCall.parse(right) do
      # The left side computes the query or declares its bindings, never a SQL operand.
      []
    else
      arguments(node, ctx, child_ctx)
    end
  end

  def structural({_form, _meta, args} = node, ctx, child_ctx) when is_list(args) do
    # Query macros build queries; even their :expression sources are Elixir, not SQL.
    # Subquery reads their clauses explicitly and sub-contracts computed sources to core.
    if QueryCall.parse(node), do: [], else: arguments(node, ctx, child_ctx)
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

  defp arguments({form, meta, args} = node, ctx, child_ctx) do
    routing = Calls.routed_treatments(node)

    for {arg, index} <- Enum.with_index(args),
        descend_arg?(routing, index),
        do: {arg, child_ctx.(node, index, ctx), &{form, meta, List.replace_at(args, index, &1)}}
  end

  @doc """
  A child's `t:slot/0`, from its parent and the parent's own slot. A Sourceror block, a written
  list and a tuple (either AST form) are transparent syntax: their elements keep the enclosing
  *call's* slot, because Ecto's constraints are on call arguments (a `json_extract_path` path
  element is constrained as the path argument is; a tuple compared with `>` is that comparison's
  operand).
  """
  @spec child_slot(Macro.t(), non_neg_integer(), slot()) :: slot()
  def child_slot({:__block__, _meta, _args}, _index, slot), do: slot
  def child_slot({:{}, _meta, _elements}, _index, slot), do: slot

  def child_slot({form, _meta, args}, index, _slot) when is_list(args),
    do: {form, length(args), index}

  def child_slot(_list_or_pair, _index, slot), do: slot

  defp inherit(_parent, _index, ctx), do: ctx

  defp descend_arg?(nil, _index), do: true
  defp descend_arg?(:skip, _index), do: false
  defp descend_arg?(routing, index), do: Enum.at(routing, index) == :expression
end
