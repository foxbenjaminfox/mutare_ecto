defmodule Mutare.Ecto.Host.Routing do
  @moduledoc """
  The **routing classifier** half of the selector host (`Mutare.Ecto.Host`): the
  `c:Mutare.Mutator.MacroAware.macro_routing/1` callback that decides, per visible argument of a
  `:routing`-registered query macro, how core should treat that position — `:hosted` (the plugin's
  host weaves it), `:expression` (mutate it normally), `:skip` (leave it raw), `:pinned` (core
  mutates a scalar value, delivered `^`-pinned), or `{:keyword, …}` (per-pair shorthand routing).
  `Mutare.Ecto.Host` then consumes the `:hosted` decision to build and weave the `^`/`dynamic` target.

  Both query syntaxes are covered, routed by call shape:

    * the `from` keyword form — `from(p in S, where: p.x == v, …)`: each `where`/`having` condition
      routes by shape, the same under a binding source (`p in S`) or a bare queryable (`from("t",
      …)`). A non-shorthand *expression* condition routes `:hosted` — under a bare source it can only
      reference a named binding (`from("t", as: :t, where: as(:t).x == v)`), which the host weaves
      behind an empty-binding `dynamic([], …)`. A keyword-**shorthand** condition (`where: [x: v]`)
      instead routes its values individually `{:keyword, …}`: each scalar value `:pinned` (core
      mutates it, `^`-pinned — Ecto rejects a bare selector `case` there, and a shorthand value is
      plain interpolated data, core's literal families to mutate, not the SQL catalog), while the
      column-name keys, the `nil`-valued pairs (an `IS NULL`, never `= nil`), and compound values are
      left raw. So a shorthand value mutation is recorded under the *core* family that made it
      (`:literal`/`:string`/…), not `:ecto`. The non-condition clauses (`select`/`order_by`/… —
      whole-`from`'s job) are always left raw.
    * the composable pipe/standalone form — `q |> where([p], p.x == v)` / `where(q, [p], …)`: the
      binding-list argument is detected by shape, and the
      condition that follows it routes `:hosted`. A **binding-less** condition
      (`q |> where(as(:post).x > 1)`) — no written list, the condition is the trailing argument —
      routes `:hosted` too (the woven `dynamic/2` re-declares an empty binding list; see
      `Mutare.Ecto.Host.Bindings`). A keyword-shorthand `where(q, x: v)` instead routes its trailing
      pairs `{:keyword, …}`. The plain clause macros (`limit`/`order_by`/…) only thread the
      query (first arg → `:expression`) and leave every data position raw for the plugin's own
      `mutate/2` mutators.

  This relies on core's recursive per-pair routing, hosted values, and `:pinned` extensions; see
  `c:Mutare.Mutator.MacroAware.macro_routing/1`.
  """

  alias Mutare.Ecto.{AST, Binding, Surface}
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.Host.Bindings
  alias Mutare.Transform.Calls

  @query_key AST.query_module_key()

  @doc """
  Per-visible-argument routing for a `:routing`-registered query macro (`from`, the `where`/`having`
  family, and the plain clause macros), consulted by Mutare core with the concrete
  node. Returns `[]` for anything else.
  """
  @spec macro_routing(Macro.t()) ::
          [Mutare.Macro.Spec.treatment() | :pinned | {:keyword, [term()]}]
  # A qualified/aliased call (`Ecto.Query.where(…)`, `Q.where(…)`) — its head is a `{:., …}` remote
  # node, not a bare macro atom, so the per-name clauses below never match it. Normalize it to its
  # bare equivalent (`Mutare.Ecto.AST.QueryCall.parse/1`, reading the resolved-macro identity core
  # stamped) and re-dispatch: routing is a list indexed by *visible argument position*, identical for
  # every written form, so the head and meta are irrelevant here. A remote head core didn't resolve
  # to a known macro yields `[]` (not a routing macro).
  # mutare:ignore[guard_drop] equivalent — `args` is a `{head, meta, args}` node's argument slot, always a list; the guard is redundant
  def macro_routing({head, _meta, args} = node) when not is_atom(head) and is_list(args) do
    case QueryCall.parse(node) do
      %QueryCall{name: name, args: visible_args} -> macro_routing({name, [], visible_args})
      nil -> []
    end
  end

  # mutare:ignore[guard_drop] equivalent — `rest` is the tail of the `[source | rest]` cons match, so it is always a list; the guard is redundant
  def macro_routing({:from, _meta, [_source | rest]}) when is_list(rest) do
    # The source is never mutated (a table/schema swap is a broken query, not a mutant). Each clause
    # routes independently: a binding-referencing `where`/`having` expression is hosted, while a
    # keyword-shorthand condition routes its values per pair so core mutates them (`^`-pinned). This
    # is the same whether the source is a binding source (`p in S`) or a bare queryable (`from("t",
    # …)`): a non-shorthand condition under a bare source can only reference a *named* binding
    # (`as(:_)`), which the host weaves behind an empty-binding `dynamic([], …)`. Non-condition
    # clauses (select/order_by/… — whole-`from`'s job), keys, and nil pairs are left raw.
    clause_treatment =
      case rest do
        # mutare:ignore[if_condition] equivalent — a from's clause argument is always a keyword list in parsed Ecto; a non-list reaches here only via malformed AST
        [clauses] when is_list(clauses) -> {:keyword, clause_treatments(clauses)}
        # `rest` is `[clauses]` for the usual `from(source, kw)`. It is `[]` for a clause-less
        # `from(Post)` (nothing to host) and anything else is malformed AST — both route `:skip`.
        _ -> :skip
      end

    [:skip | List.duplicate(clause_treatment, length(rest))]
  end

  def macro_routing({macro, _meta, args}) when is_atom(macro) and is_list(args) do
    route_macro(Surface.macro_kind(macro), args)
  end

  def macro_routing(_node), do: []

  defp route_macro(:condition, args) do
    # The threaded query (the first arg, when written directly) is an ordinary expression; its own
    # data positions stay raw. The condition/shorthand overlay then marks what the host/core own.
    base = query_threading_route(args)

    case Bindings.condition_index(args) do
      # binding form (`where(q, [u], cond)`) — host the condition after the binding list — or the
      # binding-less form (`where(q, as(:post).x > 1)`) — host the trailing condition itself.
      index when is_integer(index) -> List.replace_at(base, index, :hosted)
      # keyword-shorthand form (`where(q, col: v)`) — route the trailing keyword list per-pair.
      nil -> shorthand_route(args, base)
    end
  end

  defp route_macro(:join, args) do
    args
    |> query_threading_route()
    |> host_join_options(args)
  end

  defp route_macro(:clause, args) do
    # No hosted fragment, no shorthand: just thread the query (first arg → `:expression` when it is
    # one) and leave every data position raw for the plugin's own `mutate/2` mutators.
    query_threading_route(args)
  end

  defp route_macro(_kind, _args), do: []

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
  defp query_arg?({:|>, _meta, _args}), do: true

  defp query_arg?({name, _meta, args}) when is_atom(name) and is_list(args),
    do: Surface.query_builder?(name)

  defp query_arg?(node) do
    Binding.variable?(node) or query_builder_call?(node)
  end

  defp query_builder_call?(node) do
    case QueryCall.parse(node) do
      %QueryCall{name: name} -> Surface.query_builder?(name)
      nil -> qualified_query_builder?(Calls.resolved_call(node))
    end
  end

  # An outer routing classifier runs before core descends into its arguments, so a nested qualified
  # macro has no macro-identity stamp yet. Its explicit `Ecto.Query` receiver is nevertheless
  # authoritative through ordinary call resolution; once routed `:expression`, descent stamps and
  # analyzes it normally. Bare query builders are recognized by the clause above.
  defp qualified_query_builder?({@query_key, name, _args, _rebuild}),
    do: Surface.query_builder?(name)

  defp qualified_query_builder?(_call), do: false

  defp host_join_options(routing, args) do
    with %KeywordList{entries: entries} <- KeywordList.nonempty(List.last(args)),
         true <- Enum.any?(entries, &(&1.key == :on)) do
      List.replace_at(routing, length(args) - 1, :hosted)
    else
      _ -> routing
    end
  end

  # === keyword-shorthand routing =============================================

  # No binding list → maybe a keyword-shorthand condition (`where(q, col: v)`). Route the trailing
  # keyword-list argument `{:keyword, value_treatments}` so core mutates each scalar value
  # `^`-pinned, leaving keys and nil/compound values alone. A non-shorthand trailing arg → default.
  defp shorthand_route(args, default) do
    case args |> List.last() |> KeywordList.nonempty() do
      nil ->
        default

      pairs ->
        # mutare:ignore[operand_swap] equivalent — a shorthand call carries at most two args, where `length - 1` and `1 - length` both index the last element
        List.replace_at(default, length(args) - 1, {:keyword, pair_treatments(pairs)})
    end
  end

  # A `from`'s clause list, one treatment per clause: a `where`/`having` clause routes by its
  # condition value (below); every other clause (select/order_by/limit — whole-`from`'s job, or a
  # field-name carrier) is left raw.
  defp clause_treatments(clauses) do
    case KeywordList.parse(clauses) do
      %KeywordList{entries: entries} ->
        Enum.map(entries, fn entry ->
          if Surface.from_clause?(entry.key, :hosted),
            do: condition_treatment(entry.value),
            else: :skip
        end)

      nil ->
        []
    end
  end

  # The treatment for one `where`/`having` condition value. A keyword-shorthand value
  # (`where: [active: true]`) routes its pairs individually; a non-shorthand value (an expression
  # `where: u.x == v` or `where: as(:post).x == v`) is `:hosted` — the woven `dynamic/2` re-declares
  # the source/join bindings, or an empty list when the source is a bare queryable whose condition
  # references only a named binding (`Mutare.Ecto.Host.Bindings.from/2` builds that list). A
  # top-level interpolation (`where: ^condition`) is already evaluated in Elixir and stays raw,
  # matching the standalone binding-less condition path in `Bindings`.
  defp condition_treatment(value) do
    if top_level_pin?(value) do
      :skip
    else
      case KeywordList.nonempty(value) do
        nil -> :hosted
        pairs -> {:keyword, pair_treatments(pairs)}
      end
    end
  end

  # Sourceror may wrap a pin in a single-expression block, so recognize both shapes before the
  # condition is handed to the SQL catalog.
  defp top_level_pin?({:^, _meta, _args}), do: true
  defp top_level_pin?({:__block__, _meta, [inner]}), do: top_level_pin?(inner)
  defp top_level_pin?(_value), do: false

  defp pair_treatments(%KeywordList{entries: entries}) do
    Enum.map(entries, &pair_treatment(&1.value))
  end

  # The treatment for one shorthand pair's *value*: a scalar literal (string, number, boolean — but
  # not `nil`) is mutated by core's literal families and delivered `:pinned` (the query position
  # needs `^`). A `nil` (an `IS NULL` predicate, never `= nil`) and any compound/interpolated value
  # are left raw (`:skip`) — pinning is scalar-only, since a compound value would mutate nested nodes
  # where an inner `^` still poisons.
  defp pair_treatment(value) do
    if scalar_literal?(value), do: :pinned, else: :skip
  end

  # A Sourceror-wrapped scalar literal, excluding `nil` — an atom, but an `IS NULL`, not core's to
  # pin. `true`/`false` are atoms too and *are* pinnable; the `not is_nil/1` guard keeps only `nil`
  # out, so the ordering trap of a separate nil check disappears.
  defp scalar_literal?({:__block__, _meta, [v]}),
    do: is_binary(v) or is_number(v) or (is_atom(v) and not is_nil(v))

  defp scalar_literal?(_value), do: false
end
