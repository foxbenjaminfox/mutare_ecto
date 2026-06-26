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

  ## Routing

  Both query syntaxes are covered, routed by call shape (`macro_routing/1`):

    * the `from` keyword form — `from(p in S, where: p.x == v, …)`: the clause-bearing argument
      routes `:hosted` when the source is a binding (`p in S`), and `host/2` produces one target
      per binding-referencing `where`/`having` clause;
    * the composable pipe/standalone form — `q |> where([p], p.x == v)` / `where(q, [p], …)`:
      the binding-list argument is detected by shape and the **condition that follows it** routes
      `:hosted`.

  A bindingless `from(S, where: [x: v])` or keyword-shorthand `where(q, x: v)` carries no hosted
  *fragment* — its values are plain interpolated data, core's literal families to mutate, not the
  SQL catalog. They are routed with core's **per-keyword-pair** treatment `{:keyword, …}`: each
  `where`/`having` shorthand pair's scalar *value* is routed `:pinned` (core mutates it, delivered
  `^`-pinned — Ecto rejects a bare selector `case` there), while the column-name *keys*, the
  `nil`-valued pairs (an `IS NULL`, never `= nil`), compound values, and the non-condition clauses
  (`select`/`order_by`/… — whole-`from`'s job) are left raw. So a shorthand value mutation is
  recorded under the *core* family that made it (`:literal`/`:string`/…), not `:ecto`. This relies
  on core's per-pair routing + `:pinned` extensions (the successors to the Milestone-2 host /
  `:routing` extensions); see `c:Mutare.Mutator.macro_routing/1`.
  """

  alias Mutare.Ecto.{Aggregate, AST, Config, Fragment}

  # The clause keys whose value is a boolean condition the catalog mutates — in the `from`
  # keyword list and as standalone `Ecto.Query` macros.
  @condition_keys ~w(where or_where having or_having)a

  # The query macros (besides `from`) whose condition argument is hosted. Their binding list
  # precedes the condition both directly (`where(q, [p], cond)`) and piped (`q |> where([p], cond)`).
  @condition_macros ~w(where or_where having or_having)a

  # The remaining composable query macros — the standalone/pipe clause builders. They neither host
  # a fragment nor carry shorthand data, but they *thread a query* (the first argument, or the
  # pipe's left side), so they route through the `:routing` classifier for one reason: to mark that
  # threaded query an **`:expression`** (mutate it normally) instead of `:skip`. Routing them via
  # the classifier (rather than a static `:skip`) is also what lets core mutate the **piped left
  # side** — a static `:skip` macro stamps its piped value `:skip`, silently suppressing every
  # mutation of the upstream query (`from(…) |> limit(10)` would lose the `from`'s mutations). Their
  # own data positions (binding list, ordering, bound, selector) stay `:skip` — the plugin owns
  # those via `mutate/2` (`Mutare.Ecto.Clause`) and `Mutare.Ecto.ClauseDrop` (stage removal).
  @plain_clause_macros ~w(
    select select_merge order_by group_by distinct
    limit offset join preload lock with_cte
    windows union union_all except intersect
  )a

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
  def clause_macros, do: @plain_clause_macros

  @doc """
  Per-visible-argument routing for a `:routing`-registered query macro (`from`, the
  `where`/`having` family, and the plain clause macros), consulted by `Mutare.Transform.Resolve`
  with the concrete node. Returns `[]` for anything else.
  """
  @spec macro_routing(Macro.t()) ::
          [Mutare.Macro.Spec.treatment() | :pinned | {:keyword, [term()]}]
  # mutare:ignore[guard_drop] equivalent — `rest` is the tail of the `[source | rest]` cons match, so it is always a list; the guard is redundant
  def macro_routing({:from, _meta, [source | rest]}) when is_list(rest) do
    # Source is never mutated (a table/schema swap is a broken query, not a mutant). A binding
    # `from` hosts its clause-bearing argument (the where/having conditions); a bindingless
    # `from`'s clauses are keyword-shorthand data, routed per-pair so core mutates the
    # `where`/`having` shorthand *values* (`^`-pinned) while leaving keys, nil pairs, and the
    # other clauses (select/order_by/… — whole-`from`'s job) alone.
    clause_treatment =
      case rest do
        [clauses] ->
          cond do
            binding_source?(source) -> :hosted
            # mutare:ignore[if_condition] equivalent — a bindingless from's clause argument is always a keyword list in parsed Ecto; a non-list reaches this branch only via malformed AST
            is_list(clauses) -> {:keyword, clause_value_treatments(clauses)}
            true -> :skip
          end

        _ ->
          :skip
      end

    [:skip | List.duplicate(clause_treatment, length(rest))]
  end

  def macro_routing({macro, _meta, args}) when macro in @condition_macros and is_list(args) do
    # The threaded query (the first arg, when written directly) is an ordinary expression; its own
    # data positions stay raw. The condition/shorthand overlay then marks what the host/core own.
    base = query_threading_route(args)

    case condition_index(args) do
      # binding form (`where(q, [u], cond)`) — host the condition after the binding list.
      index when is_integer(index) -> List.replace_at(base, index, :hosted)
      # keyword-shorthand form (`where(q, col: v)`) — route the trailing keyword list per-pair.
      nil -> shorthand_route(args, base)
    end
  end

  def macro_routing({macro, _meta, args}) when macro in @plain_clause_macros and is_list(args) do
    # No hosted fragment, no shorthand: just thread the query (first arg → `:expression` when it is
    # one) and leave every data position raw for the plugin's own `mutate/2` mutators.
    query_threading_route(args)
  end

  def macro_routing(_node), do: []

  # The base routing for a query-threading macro: mark the first argument `:expression` **iff it is
  # the threaded query** (a bare query variable, a `from(…)`, or a nested pipe — not a binding list,
  # an integer bound, or an ordering written directly as the first arg, which only happens in the
  # *piped* form where the real query is the `|>` left side and already routed runtime). Every
  # remaining position is raw (`:skip`). A query position carrying nothing to mutate (a bare
  # variable) routes `:expression` harmlessly — core finds no candidates on it.
  # mutare:ignore[clause_drop] equivalent — query_threading_route only sees `[]` for an argless macro (`where()`), which valid Ecto never writes
  defp query_threading_route([]), do: []

  defp query_threading_route([first | rest]) do
    first_treatment = if query_arg?(first), do: :expression, else: :skip
    [first_treatment | List.duplicate(:skip, length(rest))]
  end

  # Whether a first-argument node is the threaded query (so it should be mutated as an expression):
  # a bare variable (`q`), a `from(…)` opener, or a nested pipe (`(… |> …)`). A binding list, a
  # keyword list, a literal, or any other DSL-data shape is not — that is a piped call's own first
  # data argument (the query is the `|>` left side, routed separately).
  # mutare:ignore[pattern_swap] equivalent — symmetric guard, body returns the constant `true`, so swapping the name/ctx binders changes nothing
  defp query_arg?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp query_arg?({:from, _meta, _args}), do: true
  defp query_arg?({:|>, _meta, _args}), do: true
  defp query_arg?(_node), do: false

  # === keyword-shorthand routing =============================================

  # No binding list → maybe a keyword-shorthand condition (`where(q, col: v)`). Route the trailing
  # keyword-list argument `{:keyword, value_treatments}` so core mutates each scalar value
  # `^`-pinned, leaving keys and nil/compound values alone. A non-shorthand trailing arg → default.
  defp shorthand_route(args, default) do
    case args |> List.last() |> shorthand_pairs() do
      nil ->
        default

      pairs ->
        # mutare:ignore[operand_swap] equivalent — a shorthand call carries at most two args, where `length - 1` and `1 - length` both index the last element
        List.replace_at(default, length(args) - 1, {:keyword, pair_value_treatments(pairs)})
    end
  end

  # A bindingless `from`'s clause list: route each `where`/`having` clause's shorthand value
  # per-pair (`{:keyword, …}`, nested — the value is itself a keyword list), and leave every other
  # clause raw (select/order_by/limit are whole-`from`'s job, or carry field names).
  defp clause_value_treatments(clauses) do
    Enum.map(clauses, fn
      {key, value} ->
        if AST.atom_value(key) in @condition_keys, do: where_value_treatment(value), else: :skip

      _other ->
        :skip
    end)
  end

  defp where_value_treatment(value) do
    case shorthand_pairs(value) do
      nil -> :skip
      pairs -> {:keyword, pair_value_treatments(pairs)}
    end
  end

  # A shorthand value list, unwrapped from the Sourceror `{:__block__, _, [list]}` it takes in a
  # keyword *value* position (the `from` form) or bare (a trailing keyword argument). `nil` when
  # the value isn't a non-empty keyword list (so it isn't shorthand — e.g. a binding list, a bare
  # field list `[:id]`, an expression).
  # mutare:ignore[guard_drop] equivalent — Sourceror block-wraps list literals, so this block clause always wraps a list; a non-list inside the block arrives only from malformed AST
  defp shorthand_pairs({:__block__, _meta, [list]}) when is_list(list), do: keyword_pairs(list)
  defp shorthand_pairs(list) when is_list(list), do: keyword_pairs(list)
  defp shorthand_pairs(_value), do: nil

  defp keyword_pairs(list) do
    # mutare:ignore[collection] equivalent — all?/any? differ only on a list mixing pairs and non-pairs, which a real binding/shorthand list never is
    if list != [] and Enum.all?(list, &match?({_k, _v}, &1)), do: list, else: nil
  end

  defp pair_value_treatments(pairs) do
    Enum.map(pairs, fn
      {_key, value} -> pair_value_treatment(value)
      _other -> :skip
    end)
  end

  # The treatment for one shorthand pair's *value*: a `nil` (an `IS NULL` predicate, never `= nil`)
  # and any compound/interpolated/expression value are left raw (`:skip`); a scalar literal
  # (string, number, atom, boolean) is mutated by core's literal families and delivered `:pinned`
  # (the query position needs `^`). Pinning is scalar-only — a compound value would mutate nested
  # nodes where an inner `^` still poisons.
  defp pair_value_treatment(value) do
    cond do
      nil_literal?(value) -> :skip
      scalar_literal?(value) -> :pinned
      true -> :skip
    end
  end

  defp nil_literal?({:__block__, _meta, [nil]}), do: true

  # mutare:ignore[clause_drop] equivalent — Sourceror block-wraps a literal nil, so the bare-nil clause is unreachable from parsed Ecto
  defp nil_literal?(nil), do: true
  defp nil_literal?(_value), do: false

  defp scalar_literal?({:__block__, _meta, [v]}), do: is_binary(v) or is_number(v) or is_atom(v)
  defp scalar_literal?(_value), do: false

  @doc """
  The selector-host targets for a query macro node — one per binding-referencing `where`/`having`
  condition with something the SQL catalog can mutate. `[]` when nothing is hostable (a
  bindingless source, a shorthand value, a condition with no catalog operators).
  """
  @spec host(Macro.t(), Mutare.Mutator.context()) :: [map()]
  # mutare:ignore[guard_drop] equivalent — a from's clause argument is always a keyword list; a non-list is malformed AST
  def host({:from, _meta, [source, clauses]}, context) when is_list(clauses) do
    case from_bindings(source, clauses) do
      [] -> []
      bindings -> from_targets(clauses, bindings, opts(context))
    end
  end

  # mutare:ignore[logical, conditional] equivalent — widening the guard admits only non-condition macros / non-list args, none of which expose a catalog-mutatable condition, so host still yields []
  def host({macro, _meta, args}, context) when macro in @condition_macros and is_list(args) do
    with index when not is_nil(index) <- condition_index(args),
         bindings = binding_decls(Enum.at(args, index - 1)),
         condition = Enum.at(args, index),
         [_ | _] = mutants <- catalog(condition, bindings, opts(context)) do
      [target(condition, mutants, bindings, condition_splice(index))]
    else
      _ -> []
    end
  end

  def host(_node, _context), do: []

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
      with true <- AST.atom_value(key) in @condition_keys,
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
  defp binding_names(bindings) do
    # mutare:ignore[logical, conditional] equivalent — the 3-tuples reaching this guard are clean vars (atom name and ctx), so it is always true; named binds are 2-tuples already excluded by the comprehension pattern
    for {name, _meta, ctx} <- bindings, is_atom(name) and is_atom(ctx), do: name
  end

  # The binding list the query establishes: the source binding(s) — a lone `u` (`u in User`) or a
  # whole binding list in the rebinding form (`[a, b] in query`, `[post: p] in query`) — followed by
  # each join's binding, in clause order. Exactly the bindings a `dynamic` re-declares — except
  # `dynamic/2` requires the named binds (`{as, var}` tuples) to come **last**, while a query may
  # rebind named sources up front and add positional joins after (`from([post: p] in q, join: c …)`).
  # So the concatenation is reordered: positional binds first (in their declared, position-defining
  # order), then the named ones — preserving each binding's identity while satisfying `dynamic/2`.
  defp from_bindings(source, clauses) do
    source_binding =
      case source do
        {:in, _, [lhs, _src]} -> binding_decls(lhs)
        _ -> []
      end

    {positional, named} =
      Enum.split_with(source_binding ++ join_bindings(clauses), &positional_binding?/1)

    positional ++ named
  end

  # A normalized binding decl is positional (a clean var, a 3-tuple `{name, meta, ctx}`) rather than
  # named (a `{key, var}` keyword pair, a 2-tuple). Named binds address by name and must sort last.
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard with a constant body (swap is a no-op), and the guard only separates a variable from a same-shaped call node, which a binding decl never holds
  defp positional_binding?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp positional_binding?(_node), do: false

  defp join_bindings(clauses) do
    for {key, {:in, _, [lhs, _src]}} <- clauses,
        # mutare:ignore[conditional] equivalent — only join clauses carry an `x in src` value; a where/having `field in ^list` has a field-access LHS yielding no binding decl, so treating it as a join adds nothing
        AST.atom_value(key) in @join_keys,
        decl <- binding_decls(lhs),
        do: decl
  end

  defp binding_source?({:in, _, [_var, _src]}), do: true
  defp binding_source?(_node), do: false

  # Replace clause `index`'s value with the `^`-pinned selector `case`, preserving the key.
  defp from_clause_splice(index, key) do
    fn {:from, meta, [source, clauses]}, case_node ->
      {:from, meta, [source, List.replace_at(clauses, index, {key, pin(case_node)})]}
    end
  end

  # === where / having (standalone + piped) ===================================

  # The condition argument's index: the position right after the binding list. Works for both
  # the direct form (`where(q, [p], cond)` — binding at 1, cond at 2) and the piped form
  # (`q |> where([p], cond)` — binding at 0, cond at 1, the query being the piped LHS, not in args).
  defp condition_index(args) do
    case Enum.find_index(args, &binding_list?/1) do
      nil -> nil
      # mutare:ignore[arithmetic, conditional, literal, relational] equivalent — these mutate the guard `index + 1 < length`, which differs only when the binding list is the last argument, where every downstream path reduces to a harmless out-of-bounds index or nil (no host either way)
      index when index + 1 < length(args) -> index + 1
      _ -> nil
    end
  end

  defp condition_splice(index) do
    fn {macro, meta, args}, case_node ->
      {macro, meta, List.replace_at(args, index, pin(case_node))}
    end
  end

  # A binding list is a (Sourceror block-wrapped) non-empty list of plain variables — `[p]`,
  # `[p, q]` — distinguishing the binding form from a keyword-shorthand value (a list of
  # `key: value` pairs) and from the query argument (a single variable, not a list).
  # mutare:ignore[guard_drop] equivalent — Sourceror block-wraps list literals, so this block clause always wraps a list
  defp binding_list?({:__block__, _, [list]}) when is_list(list), do: variable_list?(list)

  # mutare:ignore[clause_drop, return_value] equivalent — the bare-list clause is unreachable (parsed binding lists are block-wrapped, handled above), so dropping it or changing its return is unobservable
  defp binding_list?(list) when is_list(list), do: variable_list?(list)
  defp binding_list?(_node), do: false

  defp variable_list?([]), do: false

  # mutare:ignore[collection, return_value] equivalent — a real binding list is all-variables (all? and any? agree, both truthy); only a non-binding list at a non-last position would distinguish, which never occurs
  defp variable_list?(list), do: Enum.all?(list, &variable?/1)

  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard with a constant body (swap is a no-op), and the guard only separates a variable from a same-shaped call node, never present in a binding list
  defp variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # mutare:ignore[literal] equivalent — flipping the fallback to true misclassifies a non-variable element as a variable, observable only for a non-binding list at a non-last position, which never occurs
  defp variable?(_node), do: false

  # The binding declarations a binding node establishes, normalized for re-declaration in the woven
  # `dynamic([…], _)`: a lone variable (`u in User`) yields `[u]`; a binding list — positional
  # (`[a, b]`), named (`[post: p]`), or mixed (`[a, post: p]`) — expands element-wise. Positional
  # bindings become clean vars (reorder candidates via `binding_names/1`); named bindings keep their
  # key so the dynamic re-declares them faithfully, yet never become reorder candidates. Sourceror
  # block-wraps a list literal (`{:__block__, _, [list]}`); a bare list reaches here already
  # unwrapped; anything unrecognized yields `[]` (no host).
  # mutare:ignore[guard_drop] equivalent — Sourceror block-wraps list literals, so this block clause always wraps a list
  defp binding_decls({:__block__, _meta, [list]}) when is_list(list), do: binding_decls(list)
  defp binding_decls(list) when is_list(list), do: Enum.flat_map(list, &binding_decl/1)

  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard, body reuses the whole `var`, and the guard only separates a variable from a same-shaped call node, never a binding source
  defp binding_decls({name, _meta, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: [AST.clean_var(var)]

  # mutare:ignore[clause_drop] equivalent — the fallback only catches an unrecognized binding node, which valid Ecto AST never produces here
  defp binding_decls(_node), do: []

  # One binding-list element. A positional binding is a clean var; a named binding (`post: p`) is
  # re-emitted as a clean keyword pair — key normalized to the Sourceror keyword shape so the
  # renderer prints `post: p`, bound var cleaned. Anything unrecognized is dropped.
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard, body reuses the whole `var`, and the guard only separates a variable from a same-shaped call node, never a binding-list element
  defp binding_decl({name, _meta, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: [AST.clean_var(var)]

  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric inner guard, body reuses `key` and the whole `var`, and the guard only separates a variable from a same-shaped call node, never a named binding's var
  defp binding_decl({key, {name, _m, ctx} = var}) when is_atom(name) and is_atom(ctx),
    do: [{AST.keyword_key(AST.atom_value(key)), AST.clean_var(var)}]

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
