defmodule Mutare.Ecto.Host.Routing do
  @moduledoc """
  The **routing classifier** half of the selector host (`Mutare.Ecto.Host`): the
  `c:Mutare.Mutator.macro_routing/1` callback that decides, per visible argument of a
  `:routing`-registered query macro, how core should treat that position — `:hosted` (the plugin's
  host weaves it), `:expression` (mutate it normally), `:skip` (leave it raw), `:pinned` (core
  mutates a scalar value, delivered `^`-pinned), or `{:keyword, …}` (per-pair shorthand routing).
  `Mutare.Ecto.Host` then consumes the `:hosted` decision to build and weave the `^`/`dynamic` target.

  Both query syntaxes are covered, routed by call shape:

    * the `from` keyword form — `from(p in S, where: p.x == v, …)`: each binding-referencing
      condition routes `:hosted` while shorthand conditions route their values individually. A
      bindingless `from(S, where: [x: v])` carries
      no hosted *fragment* — its values are plain interpolated data, core's literal families to
      mutate, not the SQL catalog — so its `where`/`having` shorthand *values* route `{:keyword, …}`:
      each scalar value `:pinned` (core mutates it, `^`-pinned — Ecto rejects a bare selector `case`
      there), while the column-name keys, the `nil`-valued pairs (an `IS NULL`, never `= nil`),
      compound values, and the non-condition clauses (`select`/`order_by`/… — whole-`from`'s job) are
      left raw. So a shorthand value mutation is recorded under the *core* family that made it
      (`:literal`/`:string`/…), not `:ecto`.
    * the composable pipe/standalone form — `q |> where([p], p.x == v)` / `where(q, [p], …)`: the
      binding-list argument is detected by shape (`Mutare.Ecto.Host.condition_index/1`) and the
      condition that follows it routes `:hosted`; a keyword-shorthand `where(q, x: v)` routes its
      trailing pairs `{:keyword, …}`. The plain clause macros (`limit`/`order_by`/…) only thread the
      query (first arg → `:expression`) and leave every data position raw for the plugin's own
      `mutate/2` mutators.

  This relies on core's recursive per-pair routing, hosted values, and `:pinned` extensions; see
  `c:Mutare.Mutator.macro_routing/1`.
  """

  alias Mutare.Ecto.{AST, Binding, Surface}
  alias Mutare.Ecto.Host.Bindings
  alias Mutare.Transform.Calls

  # The where/having family and the plain composable clause macros, as compile-time guard constants.
  # The canonical lists live on `Mutare.Ecto.Surface`; the
  # condition macros double as the `from`-clause condition keys (`where`/`or_where`/`having`/…).
  @condition_macros Surface.condition_macros()
  @hosted_clause_keys Surface.hosted_clause_keys()
  @plain_clause_macros Surface.clause_macros()
  @query_builders Surface.query_builders()
  @query_key AST.module_key(Ecto.Query)

  @doc """
  Per-visible-argument routing for a `:routing`-registered query macro (`from`, the `where`/`having`
  family, and the plain clause macros), consulted by `Mutare.Transform.Resolve` with the concrete
  node. Returns `[]` for anything else.
  """
  @spec macro_routing(Macro.t()) ::
          [Mutare.Macro.Spec.treatment() | :pinned | {:keyword, [term()]}]
  # A qualified/aliased call (`Ecto.Query.where(…)`, `Q.where(…)`) — its head is a `{:., …}` remote
  # node, not a bare macro atom, so the per-name clauses below never match it. Normalize it to its
  # bare equivalent (`Mutare.Ecto.AST.query_macro_call/1`, reading the resolved-macro identity core
  # stamped) and re-dispatch: routing is a list indexed by *visible argument position*, identical for
  # every written form, so the head and meta are irrelevant here. A remote head core didn't resolve
  # to a known macro yields `[]` (not a routing macro).
  # mutare:ignore[guard_drop] equivalent — `args` is a `{head, meta, args}` node's argument slot, always a list; the guard is redundant
  def macro_routing({head, _meta, args} = node) when not is_atom(head) and is_list(args) do
    case AST.query_macro_call(node) do
      {name, visible_args, _rebuild} -> macro_routing({name, [], visible_args})
      nil -> []
    end
  end

  # mutare:ignore[guard_drop] equivalent — `rest` is the tail of the `[source | rest]` cons match, so it is always a list; the guard is redundant
  def macro_routing({:from, _meta, [source | rest]}) when is_list(rest) do
    # Source is never mutated (a table/schema swap is a broken query, not a mutant). A binding
    # `from` routes each clause independently: binding-referencing conditions are hosted, while
    # shorthand conditions are routed per pair. A bindingless `from`'s clauses are
    # keyword-shorthand data, routed per-pair so core mutates the
    # `where`/`having` shorthand *values* (`^`-pinned) while leaving keys, nil pairs, and the
    # other clauses (select/order_by/… — whole-`from`'s job) alone.
    clause_treatment =
      case rest do
        [clauses] ->
          cond do
            binding_source?(source) -> {:keyword, clause_value_treatments(clauses, :binding)}
            # mutare:ignore[if_condition] equivalent — a bindingless from's clause argument is always a keyword list in parsed Ecto; a non-list reaches this branch only via malformed AST
            is_list(clauses) -> {:keyword, clause_value_treatments(clauses, :bindingless)}
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

    case Bindings.condition_index(args) do
      # binding form (`where(q, [u], cond)`) — host the condition after the binding list.
      index when is_integer(index) -> List.replace_at(base, index, :hosted)
      # keyword-shorthand form (`where(q, col: v)`) — route the trailing keyword list per-pair.
      nil -> shorthand_route(args, base)
    end
  end

  def macro_routing({:join, _meta, args}) when is_list(args) do
    args
    |> query_threading_route()
    |> host_join_options(args)
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

  # Whether a first-argument node is a query expression that should remain reachable: a bare
  # variable (`q`), any nested query-builder macro (`from(…)`, `where(…)`, …), or a nested pipe.
  # A binding list, keyword list, literal, or other DSL-data shape is not — that is a piped call's
  # own first data argument (the threaded query is the `|>` left side, routed separately).
  defp query_arg?({name, _meta, args}) when name in @query_builders and is_list(args), do: true
  defp query_arg?({:|>, _meta, _args}), do: true

  defp query_arg?(node) do
    Binding.variable?(node) or query_builder_call?(node)
  end

  defp query_builder_call?(node) do
    case AST.query_macro_call(node) do
      {name, _args, _rebuild} -> name in @query_builders
      nil -> qualified_query_builder?(Calls.resolved_call(node))
    end
  end

  # An outer routing classifier runs before core descends into its arguments, so a nested qualified
  # macro has no macro-identity stamp yet. Its explicit `Ecto.Query` receiver is nevertheless
  # authoritative through ordinary call resolution; once routed `:expression`, descent stamps and
  # analyzes it normally. Bare query builders are recognized by the clause above.
  defp qualified_query_builder?({@query_key, name, _args, _rebuild}),
    do: name in @query_builders

  defp qualified_query_builder?(_call), do: false

  # A `from` source is a *binding* source (`p in S`, `[a, b] in q`) — routed `:hosted` — rather than
  # a bare queryable (`from("users", …)`), whose clauses are keyword-shorthand data.
  defp binding_source?({:in, _, [_var, _src]}), do: true
  defp binding_source?(_node), do: false

  defp host_join_options(routing, args) do
    with [_ | _] = options <- List.last(args),
         true <- Enum.any?(options, &on_pair?/1) do
      List.replace_at(routing, length(args) - 1, :hosted)
    else
      _ -> routing
    end
  end

  defp on_pair?({key, _value}), do: AST.atom_value(key) == :on
  defp on_pair?(_node), do: false

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
  defp clause_value_treatments(clauses, source_kind) do
    Enum.map(clauses, fn
      {key, value} ->
        if AST.atom_value(key) in @hosted_clause_keys,
          do: condition_value_treatment(value, source_kind),
          else: :skip

      _other ->
        :skip
    end)
  end

  defp condition_value_treatment(value, :binding) do
    case shorthand_pairs(value) do
      nil -> :hosted
      pairs -> {:keyword, pair_value_treatments(pairs)}
    end
  end

  defp condition_value_treatment(value, :bindingless), do: where_value_treatment(value)

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
end
