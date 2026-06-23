defmodule Mutare.Ecto.Host do
  @moduledoc """
  The **selector-host** half of Bucket 3 (`DESIGN.md`): localized, in-fragment mutations of a
  `where`/`having` condition, delivered through Mutare core's mutator-supplied host
  (`c:Mutare.Mutator.host/2`) and shape-aware routing (`c:Mutare.Mutator.macro_routing/1`).

  A query clause cannot host a runtime `case` — it is macro-expanded into query AST at compile
  time — but Ecto's `^` interpolation plus `dynamic/2` injects a runtime-chosen fragment the
  query *actually runs*, and the active mutant id is constant for a run, so exactly one branch
  bakes into the compiled query. This module hands core, per mutatable condition, the
  `{original, mutants}` pair (from `Mutare.Ecto.Fragment`'s SQL catalog) plus two pure
  transforms:

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

  alias Mutare.Ecto.{AST, Config, Fragment}

  # The clause keys whose value is a boolean condition the catalog mutates — in the `from`
  # keyword list and as standalone `Ecto.Query` macros.
  @condition_keys ~w(where or_where having or_having)a

  # The query macros (besides `from`) whose condition argument is hosted. Their binding list
  # precedes the condition both directly (`where(q, [p], cond)`) and piped (`q |> where([p], cond)`).
  @condition_macros ~w(where or_where having or_having)a

  # `from` keyword keys that introduce an extra positional binding (`join: p in assoc(u, :x)`),
  # so the woven `dynamic` re-declares the full binding list the query establishes.
  @join_keys ~w(
    join inner_join left_join right_join full_join cross_join
    inner_lateral_join left_lateral_join
  )a

  @doc """
  Per-visible-argument routing for a `:routing`-registered query macro (`from` and the
  `where`/`having` family), consulted by `Mutare.Transform.Resolve` with the concrete node.
  Returns `[]` for anything else.
  """
  @spec macro_routing(Macro.t()) ::
          [Mutare.Macro.Spec.treatment() | :pinned | {:keyword, [term()]}]
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
            is_list(clauses) -> {:keyword, clause_value_treatments(clauses)}
            true -> :skip
          end

        _ ->
          :skip
      end

    [:skip | List.duplicate(clause_treatment, length(rest))]
  end

  def macro_routing({macro, _meta, args}) when macro in @condition_macros and is_list(args) do
    default = List.duplicate(:skip, length(args))

    case condition_index(args) do
      # binding form (`where(q, [u], cond)`) — host the condition after the binding list.
      index when is_integer(index) -> List.replace_at(default, index, :hosted)
      # keyword-shorthand form (`where(q, col: v)`) — route the trailing keyword list per-pair.
      nil -> shorthand_route(args, default)
    end
  end

  def macro_routing(_node), do: []

  # === keyword-shorthand routing =============================================

  # No binding list → maybe a keyword-shorthand condition (`where(q, col: v)`). Route the trailing
  # keyword-list argument `{:keyword, value_treatments}` so core mutates each scalar value
  # `^`-pinned, leaving keys and nil/compound values alone. A non-shorthand trailing arg → default.
  defp shorthand_route(args, default) do
    case args |> List.last() |> shorthand_pairs() do
      nil ->
        default

      pairs ->
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
  defp shorthand_pairs({:__block__, _meta, [list]}) when is_list(list), do: keyword_pairs(list)
  defp shorthand_pairs(list) when is_list(list), do: keyword_pairs(list)
  defp shorthand_pairs(_value), do: nil

  defp keyword_pairs(list) do
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
  def host({:from, _meta, [source, clauses]}, context) when is_list(clauses) do
    case from_bindings(source, clauses) do
      [] -> []
      bindings -> from_targets(clauses, bindings, opts(context))
    end
  end

  def host({macro, _meta, args}, context) when macro in @condition_macros and is_list(args) do
    with index when not is_nil(index) <- condition_index(args),
         bindings = binding_vars(Enum.at(args, index - 1)),
         condition = Enum.at(args, index),
         [_ | _] = mutants <- catalog(condition, bindings, opts(context)) do
      [target(condition, mutants, bindings, condition_splice(index))]
    else
      _ -> []
    end
  end

  def host(_node, _context), do: []

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
  # catalog (`Fragment.mutants/2`, dialect-gated by `opts`) plus the binding-reorder swaps the
  # declared bindings admit, each tagged with its family and filtered to the configured
  # `families:`. Both ride the same `dynamic([bindings], _)` wrap.
  defp catalog(condition, bindings, opts) do
    reorders =
      for node <- Fragment.binding_reorders(condition, binding_names(bindings)),
          do: {:binding_reorder, node}

    for {family, node} <- Fragment.mutants(condition, opts) ++ reorders,
        Config.family_enabled?(opts, family),
        do: node
  end

  defp binding_names(bindings), do: Enum.map(bindings, fn {name, _meta, _ctx} -> name end)

  # The binding list the query establishes: the source binding (`u` in `u in User`) followed by
  # each join's binding, in clause order — exactly the positional bindings a `dynamic` re-declares.
  defp from_bindings(source, clauses) do
    source_binding =
      case source do
        {:in, _, [var, _src]} -> [AST.clean_var(var)]
        _ -> []
      end

    source_binding ++ join_bindings(clauses)
  end

  defp join_bindings(clauses) do
    for {key, {:in, _, [var, _src]}} <- clauses,
        AST.atom_value(key) in @join_keys,
        do: AST.clean_var(var)
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
  defp binding_list?({:__block__, _, [list]}) when is_list(list), do: variable_list?(list)
  defp binding_list?(list) when is_list(list), do: variable_list?(list)
  defp binding_list?(_node), do: false

  defp variable_list?([]), do: false
  defp variable_list?(list), do: Enum.all?(list, &variable?/1)

  defp variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_node), do: false

  defp binding_vars({:__block__, _, [list]}) when is_list(list),
    do: Enum.map(list, &AST.clean_var/1)

  defp binding_vars(list) when is_list(list), do: Enum.map(list, &AST.clean_var/1)

  # === shared ================================================================

  defp target(original, mutants, bindings, splice) do
    %{original: original, mutants: mutants, wrap: dynamic_wrap(bindings), splice: splice}
  end

  # `&Ecto.Query.dynamic([bindings], &1)` as a 1-arity transform core applies to each branch
  # fragment. Fully qualified (and `Elixir.`-anchored, alias-proof) so it resolves regardless of
  # how `Ecto.Query` was imported.
  defp dynamic_wrap(bindings) do
    fn fragment ->
      {{:., [], [{:__aliases__, [], [:"Elixir", :Ecto, :Query]}, :dynamic]}, [],
       [bindings, fragment]}
    end
  end

  defp pin(case_node), do: {:^, [], [case_node]}
end
