defmodule Mutare.Ecto.Host do
  @moduledoc """
  The **selector-host** half of Bucket 3 (`DESIGN.md`): localized, in-fragment mutations of a
  `where`/`having` condition, delivered through Mutare core's mutator-supplied host
  (`c:Mutare.Mutator.host/2`) and shape-aware routing (`c:Mutare.Mutator.macro_routing/1`).

  A query clause cannot host a runtime `case` — it is macro-expanded into query AST at compile
  time — but Ecto's `^` interpolation plus `dynamic/2` injects a runtime-chosen fragment the
  query *actually runs*, and the active mutant id is constant for a run, so exactly one branch
  bakes into the compiled query. This module hands core, per mutatable condition, the
  `{original, mutants}` pair (from `Mutare.Ecto.Fragment`'s SQL catalog, plus the shared
  `Mutare.Ecto.Aggregate` walker for an aggregate inside a `having` — `sum`↔`avg`, `min`↔`max`)
  plus two pure transforms:

    * **`wrap`** — `&Ecto.Query.dynamic([bindings], &1)`, mapping each logical branch fragment
      to the value the clause position runs. The `[bindings]` are re-declared from the enclosing
      `from`/pipe-stage binding list. Fully-qualified so it resolves under a selective
      `import Ecto.Query, only: …` that didn't import `dynamic`.
    * **`splice`** — weaves the assembled selector `case` into a copy of the macro node,
      `^`-pinned at the clause/condition position.

  Core owns everything structural — the selector subject, the `<id> ->` clauses, id assignment,
  the coverage catch-all, and the `Mutare.Site` (recorded from the *logical* pair, so the diff
  is `u.x == u.y` → `!=`, the `dynamic`/`^` scaffolding invisible).

  The companion `Mutare.Ecto.Host.Routing` owns the other half — the `macro_routing/1` classifier
  that decides *which* argument positions are `:hosted` (and how the rest route); this module then
  builds and weaves the targets for those positions. `condition_index/1` (the binding-list/condition
  shape detection) is shared by both and lives here.
  """

  alias Mutare.Ecto.{Aggregate, AST, Binding, Config, Fragment, Surface}

  # The query macros whose condition argument is hosted (the `where`/`having` family). The same set
  # doubles as the `from`-clause condition *keys* (`where:`/`having:`/…) — they are one and the same.
  # Their binding list precedes the condition both directly (`where(q, [p], cond)`) and piped
  # (`q |> where([p], cond)`). Public via `condition_macros/0` so `Mutare.Ecto.Host.Routing` shares it.
  @condition_macros Surface.condition_macros()

  # `from` keyword keys that introduce an extra positional binding (`join: p in assoc(u, :x)`),
  # so the woven `dynamic` re-declares the full binding list the query establishes.
  @join_keys ~w(
    join inner_join left_join right_join full_join cross_join
    inner_lateral_join left_lateral_join
  )a

  @doc "The hosted condition macros (`where`/`having` family), registered `:routing` by the plugin."
  @spec condition_macros() :: [atom()]
  def condition_macros, do: @condition_macros

  @doc "The plain composable clause macros (`limit`/`order_by`/…), registered `:routing` by the plugin."
  @spec clause_macros() :: [atom()]
  defdelegate clause_macros, to: Surface

  @doc """
  The selector-host targets for a query macro node — one per binding-referencing `where`/`having`
  condition with something the SQL catalog can mutate. `[]` when nothing is hostable (a
  bindingless source, a shorthand value, a condition with no catalog operators).
  """
  # Normalize the call to its bare equivalent (`Mutare.Ecto.AST.query_macro_call/1`) before matching,
  # so the qualified (`Ecto.Query.where(…)`) and aliased (`Q.where(…)`) forms host their conditions
  # exactly like the bare/imported form — core hands `host/2` the visible call node in whatever form
  # the source wrote it.
  @spec host(Macro.t(), Mutare.Mutator.context()) :: [map()]
  def host(node, context) do
    case AST.query_macro_call(node) do
      # mutare:ignore[guard_drop] equivalent — a from's clause argument is always a keyword list; a non-list is malformed AST
      {:from, [source, clauses], _rebuild} when is_list(clauses) ->
        from_host(source, clauses, context)

      # mutare:ignore[logical, conditional] equivalent — widening the guard admits only non-condition macros / non-list args, none of which expose a catalog-mutatable condition, so host still yields []
      {macro, args, _rebuild} when macro in @condition_macros and is_list(args) ->
        condition_host(args, context)

      _ ->
        []
    end
  end

  defp from_host(source, clauses, context) do
    case from_bindings(source, clauses) do
      [] -> []
      bindings -> from_targets(clauses, bindings, opts(context))
    end
  end

  defp condition_host(args, context) do
    with index when not is_nil(index) <- condition_index(args),
         bindings = binding_decls(Enum.at(args, index - 1)),
         condition = Enum.at(args, index),
         [_ | _] = mutants <- catalog(condition, bindings, opts(context)) do
      [target(condition, mutants, bindings, condition_splice(index))]
    else
      _ -> []
    end
  end

  # mutare:ignore[guard_drop] equivalent — context.opts is always a keyword list; a non-list never reaches here
  defp opts(%{opts: opts}) when is_list(opts), do: opts
  defp opts(_context), do: []

  # === from ==================================================================

  # One target per `where`/`having` clause whose value the catalog mutates. The clause index is
  # captured so the splice replaces *its own* clause (multiple targets fold over the node, each
  # replacing a distinct position — `List.replace_at` keeps the list length, so indices stay valid).
  defp from_targets(clauses, bindings, opts) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {{key, value}, index} ->
      with true <- AST.atom_value(key) in @condition_macros,
           [_ | _] = mutants <- catalog(value, bindings, opts) do
        [target(value, mutants, bindings, from_clause_splice(index, key))]
      else
        _ -> []
      end
    end)
  end

  # The enabled logical mutants for a `where`/`having` condition: the SQL-operator/predicate
  # catalog (`Fragment.mutants/2`, dialect-gated by `opts`), the binding-reorder swaps the declared
  # bindings admit, and the aggregate swaps the condition admits (`Aggregate.swaps/1` — `sum`↔`avg`,
  # `min`↔`max`, the in-fragment cousin of the `select`/`Repo.aggregate` swap, fired on a
  # `having: sum(p.x) > n`), each tagged with its family and filtered to the configured `families:`.
  # All ride the same `dynamic([bindings], _)` wrap. An equivalence-sensitive family is wrapped by
  # `Config.noted/2` in a `%Mutare.Mutator.Mutation{}` so the report flags "kill may require
  # NULL/boundary data".
  defp catalog(condition, bindings, opts) do
    reorders =
      for node <- Fragment.binding_reorders(condition, binding_names(bindings)),
          do: {:binding_reorder, node}

    aggregates = for node <- Aggregate.swaps(condition), do: {:aggregate, node}

    # mutare:ignore[operand_swap] equivalent — the mutants are consumed as a set, so their concatenation order is irrelevant
    for {family, node} <- Fragment.mutants(condition, opts) ++ reorders ++ aggregates,
        Config.family_enabled?(opts, family),
        do: Config.noted(family, node)
  end

  # The positional binding names eligible for reorder, drawn from the declarations `binding_decls/1`
  # produced. Named bindings (`post: p`) are deliberately excluded: a reorder is a *positional*
  # transposition (`[a, b]` → `[b, a]`), meaningless for a name-addressed binding, so a named binding
  # rides the query untouched while its positional siblings still swap.
  defp binding_names(bindings), do: for(b <- bindings, Binding.variable?(b), do: elem(b, 0))

  # The binding list the query establishes, re-declared for the woven `dynamic([…], _)`. It is
  # assembled in four ordered parts:
  #
  #   1. **source-pattern positionals** — `[a, b]` from `[a, b] in query` (or the lone `u` of
  #      `u in User`). They rebind the source query's *leading* positions, so they stay at the front.
  #   2. **`...`** (the tail anchor) — emitted only when there are join positionals whose absolute
  #      position the host can't pin down: the source rebinds *named* sources, or contributes no
  #      positional of its own (`[as: x] in query`, a bindingless `from(query, …)`). A join binding is
  #      appended after *all* of the opaque source query's bindings, and a named bind consumes no
  #      position — so without `...` a lone trailing join silently re-binds to position 0
  #      (BUG-from_bindings-named-rebind-join). `...` pins each join to its true tail position. When
  #      the source is a leading positional run with no named rebind, the joins follow it contiguously
  #      and no anchor is needed (`[u, c]` / `[a, b, c]` is unchanged). A `...` the source pattern
  #      *itself* writes (`[..., c] in query`) is preserved in place and already anchors the tail, so
  #      the host adds no second one — the joins just follow the source's positionals (`[..., c, j]`).
  #   3. **join positionals** — each `join`'s binding (`@join_keys`), in clause order, behind the
  #      anchor.
  #   4. **source-pattern named binds** — the `{as, var}` tuples, which `dynamic/2` requires **last**
  #      and which resolve by name (no position). Joins contribute none (they bind positionally).
  defp from_bindings(source, clauses) do
    source_decls =
      case source do
        {:in, _, [lhs, _src]} -> binding_decls(lhs)
        _ -> []
      end

    # The source pattern's named binds sort to the end (`dynamic/2` requires it; they resolve by name,
    # not position); its positionals — and any explicit `...` — keep their declared order at the front,
    # since `[a, ..., c]` declares distinct positions (`a`@0, `c` last) that must be preserved verbatim.
    {source_named, source_front} = Enum.split_with(source_decls, &named_binding?/1)

    # Joins bind positionally — a join clause's lhs is a variable (named joins use `as:`, a separate
    # option, not a binding-pattern entry) — so every join decl is a positional reorder candidate. The
    # `[]` asserts that: a named join decl (which would need sorting last) raises here rather than
    # being silently mis-positioned.
    {join_positional, []} = Enum.split_with(join_bindings(clauses), &Binding.variable?/1)

    source_front ++ positioned_joins(source_front, source_named, join_positional) ++ source_named
  end

  # The join positionals, placed so each maps to its true tail position. When the source pattern
  # already carries an explicit `...` (`[..., c] in q`), that anchor pins the tail, so the joins
  # follow the source's positionals contiguously (`[..., c, j]`). Otherwise `join_anchor/3` supplies
  # the `...` itself when the leading positions are opaque.
  defp positioned_joins(source_front, source_named, join_positional) do
    if Enum.any?(source_front, &Binding.ellipsis?/1),
      do: join_positional,
      else: join_anchor(source_front, source_named, join_positional)
  end

  # The join positionals, anchored to the query's tail with a leading `...` when the host cannot
  # know how many of the opaque source query's bindings precede them — i.e. when there *are* join
  # positionals and the source either rebinds a named source or contributes no positional of its own.
  # A leading positional run with no named rebind (`u in User`, `[a, b] in q`) places the joins
  # contiguously after it, so no anchor is needed.
  defp join_anchor(source_positional, source_named, join_positional) do
    if join_positional != [] and (source_positional == [] or source_named != []) do
      [Binding.ellipsis() | join_positional]
    else
      join_positional
    end
  end

  # A named binding decl — the `{key, var}` keyword pair `binding_decl/1` emits for `post: p`. Used to
  # peel named binds (which `dynamic/2` requires last) off the source pattern while leaving its
  # positionals (`Binding.variable?/1`) *and* any `...` anchor (`Binding.ellipsis?/1`) in place.
  defp named_binding?({_key, _var}), do: true
  defp named_binding?(_node), do: false

  defp join_bindings(clauses) do
    for {key, {:in, _, [lhs, _src]}} <- clauses,
        # mutare:ignore[conditional] equivalent — only join clauses carry an `x in src` value; a where/having `field in ^list` has a field-access LHS yielding no binding decl, so treating it as a join adds nothing
        AST.atom_value(key) in @join_keys,
        decl <- binding_decls(lhs),
        do: decl
  end

  # Replace clause `index`'s value with the `^`-pinned selector `case`, preserving the key — and the
  # source's written form. The node is re-normalized each fold (`AST.query_macro_call/1`) rather than
  # destructured, so a qualified/aliased `from` weaves correctly and `rebuild` re-emits in its own
  # form; multiple targets fold over the same node, each re-reading the (partly spliced) clause list.
  defp from_clause_splice(index, key) do
    fn node, case_node ->
      {:from, [source, clauses], rebuild} = AST.query_macro_call(node)
      rebuild.(:from, [source, List.replace_at(clauses, index, {key, pin(case_node)})])
    end
  end

  # === where / having (standalone + piped) ===================================

  @doc """
  The condition argument's index for a `where`/`having` macro call — the position right after the
  binding list — or `nil` when the call carries no binding list (a keyword-shorthand form). Works for
  both the direct form (`where(q, [p], cond)` — binding at 1, cond at 2) and the piped form
  (`q |> where([p], cond)` — binding at 0, cond at 1, the query being the piped LHS, not in args).
  Shared shape detection: `Mutare.Ecto.Host.Routing` uses it to mark the condition position `:hosted`,
  and `host/2` (below) to locate the condition it weaves.
  """
  @spec condition_index([Macro.t()]) :: non_neg_integer() | nil
  def condition_index(args) do
    case Enum.find_index(args, &binding_list?/1) do
      nil -> nil
      # mutare:ignore[arithmetic, conditional, literal, relational] equivalent — these mutate the guard `index + 1 < length`, which differs only when the binding list is the last argument, where every downstream path reduces to a harmless out-of-bounds index or nil (no host either way)
      index when index + 1 < length(args) -> index + 1
      _ -> nil
    end
  end

  # Pin the condition at `index`, preserving the macro and the source's written form (bare/qualified/
  # aliased) via the node's own `rebuild` — re-normalized from the node core hands the splice.
  defp condition_splice(index) do
    fn node, case_node ->
      {name, args, rebuild} = AST.query_macro_call(node)
      rebuild.(name, List.replace_at(args, index, pin(case_node)))
    end
  end

  # A binding list is a (Sourceror block-wrapped) non-empty list of positional variables, named
  # bindings, and/or an optional `...` anchor. A named list (`[post: p]`) is distinguished from
  # keyword shorthand by `condition_index/1`: only a list with a following condition is a binding
  # declaration; a trailing keyword list remains shorthand.
  defp binding_list?(node) do
    case Binding.unwrap_list(node) do
      # mutare:ignore[collection, return_value] equivalent — a real binding list is all binding-list elements (all? and any? agree, both truthy); only a non-binding list at a non-last position would distinguish, which never occurs
      [_ | _] = list -> Enum.all?(list, &binding_list_element?/1)
      _ -> false
    end
  end

  defp binding_list_element?(node), do: Binding.entry?(node)

  # The binding declarations a binding node establishes, normalized for re-declaration in the woven
  # `dynamic([…], _)`: a binding list — positional (`[a, b]`), named (`[post: p]`), mixed
  # (`[a, post: p]`), or `...`-anchored (`[..., c]`) — expands element-wise via `binding_decl/1`; a
  # lone variable (`u in User`) is a single decl (`Binding.unwrap_list/1` returns `nil`, so it routes
  # straight to `binding_decl/1`, which yields `[u]`); anything unrecognized yields `[]` (no host).
  defp binding_decls(node) do
    case Binding.unwrap_list(node) do
      nil -> binding_decl(node)
      list -> Enum.flat_map(list, &binding_decl/1)
    end
  end

  # One binding-list element. A positional binding is a clean var; a named binding (`post: p`) is
  # re-emitted as a clean keyword pair — key normalized to the Sourceror keyword shape so the
  # renderer prints `post: p`, bound var cleaned. Anything unrecognized is dropped.
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard, body reuses the whole `var`, and the guard only separates a variable from a same-shaped call node, never a binding-list element
  defp binding_decl({name, _meta, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: [AST.clean_var(var)]

  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric inner guard, body reuses `key` and the whole `var`, and the guard only separates a variable from a same-shaped call node, never a named binding's var
  defp binding_decl({key, {name, _m, ctx} = var}) when is_atom(name) and is_atom(ctx),
    do: [{AST.keyword_key(AST.atom_value(key)), AST.clean_var(var)}]

  # The `...` tail anchor (`[..., c] in q`) — preserved (re-emitted clean-meta) so the woven dynamic
  # keeps the source pattern's own anchor and maps each trailing binding to its true position.
  defp binding_decl({:..., _meta, _ctx}), do: [Binding.ellipsis()]

  # mutare:ignore[clause_drop] equivalent — the fallback only catches an unrecognized binding-list element, which valid Ecto AST never produces here
  defp binding_decl(_node), do: []

  # === shared ================================================================

  defp target(original, mutants, bindings, splice) do
    %{original: original, mutants: mutants, wrap: dynamic_wrap(bindings), splice: splice}
  end

  # `&Ecto.Query.dynamic([bindings], &1)` as a 1-arity transform core applies to each branch
  # fragment. Fully qualified (and `Elixir.`-anchored, alias-proof) so it resolves regardless of
  # how `Ecto.Query` was imported.
  defp dynamic_wrap(bindings) do
    fn fragment ->
      AST.remote_call(AST.absolute_alias([:Ecto, :Query]), :dynamic, [bindings, fragment])
    end
  end

  defp pin(case_node), do: {:^, [], [case_node]}
end
