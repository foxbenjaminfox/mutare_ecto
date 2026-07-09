defmodule Mutare.Ecto.Host.Routing do
  @moduledoc """
  The **routing classifier** half of the selector host (`Mutare.Ecto.Host`): the
  `c:Mutare.MacroRouting.route_arguments/2` callback that decides, per visible argument of a
  `:routing`-registered query macro, how core should treat that position — `:hosted` (the plugin's
  host weaves it), `:expression` (mutate it normally), `:skip` (leave it raw), `:interpolated`
  (core mutates a scalar value, delivered through `^` interpolation), or `{:keyword, …}` (per-pair
  shorthand routing).
  `Mutare.Ecto.Host` then consumes the `:hosted` decision to build and weave the `^`/`dynamic` target.

  Both query syntaxes are covered, routed by call shape:

    * the `from` keyword form — `from(p in S, where: p.x == v, …)`: each `where`/`having` condition
      routes by shape, the same under a binding source (`p in S`) or a bare queryable (`from("t",
      …)`). A non-shorthand *expression* condition routes `:hosted` — under a bare source it can only
      reference a named binding (`from("t", as: :t, where: as(:t).x == v)`), which the host weaves
      behind an empty-binding `dynamic([], …)`. A keyword-**shorthand** condition (`where: [x: v]`)
      instead routes its values individually `{:keyword, …}`: each scalar value `:interpolated` (core
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
      query (first arg → `:expression`) and leave their data positions raw for the plugin's own
      `mutate/2` mutators — with one exception: a **literal-integer bound** (`limit(q, 10)` /
      `q |> offset(5)`, and the `limit:`/`offset:` keys of the `from` keyword form) routes
      `:hosted`, so the `:bound` ±1 bump weaves pin-only (`limit: ^(case …)`) instead of
      duplicating the whole call. The literal-only guard is the host's own
      (`Mutare.Ecto.Host.Catalog.bound_literal?/1`, defined as `bounds/1` producing mutants), so
      routing and host agree by definition — a `^pinned`/expression bound stays raw exactly as
      before.

  This relies on core's recursive per-pair routing, hosted values, and `:interpolated` extensions; see
  `c:Mutare.MacroRouting.route_arguments/2`.
  """

  alias Mutare.Ecto.{Binding, Surface}
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.Host.{Bindings, Catalog}
  alias Mutare.Calls
  alias Mutare.MacroRouting.{ArgumentRoutes, Call}

  @doc """
  `c:Mutare.MacroRouting.route_arguments/2` for a `:routing`-registered query macro: the
  per-visible-argument `treatments/1` classification, wrapped as `ArgumentRoutes`. Core hands in a
  resolved `Mutare.MacroRouting.Call`, so the written form (bare/qualified/aliased/piped) is already
  normalized. A piped call's hidden left side is the threaded query, so it keeps `from_visible`'s
  `:expression` default — the upstream query stays mutable through the stage.
  """
  @spec route_arguments(Call.t(), Mutare.MacroRouting.routing_context()) :: ArgumentRoutes.t()
  def route_arguments(%Call{name: name, arguments: args} = call, _context) do
    ArgumentRoutes.from_visible(call, treatments({name, [], args}))
  end

  @doc """
  Per-visible-argument treatment for a `:routing`-registered query macro (`from`, the
  `where`/`having` family, `join`, and the plain clause macros), one entry per visible argument.
  Returns `[]` for anything else.
  """
  @spec treatments(Macro.t()) :: [Mutare.MacroRouting.treatment()]
  # mutare:ignore[guard_drop] equivalent — `rest` is the tail of the `[source | rest]` cons match, so it is always a list; the guard is redundant
  def treatments({:from, _meta, [_source | rest]}) when is_list(rest) do
    # The source is never mutated (a table/schema swap is a broken query, not a mutant). Each clause
    # routes independently: a binding-referencing `where`/`having` expression is hosted, while a
    # keyword-shorthand condition routes its values per pair so core mutates them (`^`-pinned). This
    # is the same whether the source is a binding source (`p in S`) or a bare queryable (`from("t",
    # …)`): a non-shorthand condition under a bare source can only reference a *named* binding
    # (`as(:_)`), which the host weaves behind an empty-binding `dynamic([], …)`. Non-condition
    # clauses (select/order_by/… — whole-`from`'s job), keys, and nil pairs are left raw.
    clause_treatment =
      case rest do
        # mutare:ignore[guard_drop] equivalent — `clause_treatments/1` parses `clauses` via `KeywordList.parse/1`, which already returns `nil`/`[]` safely for a non-list, so dropping this guard doesn't crash or change behavior for malformed AST
        [clauses] when is_list(clauses) -> {:keyword, clause_treatments(clauses)}
        # `rest` is `[clauses]` for the usual `from(source, kw)`. It is `[]` for a clause-less
        # `from(Post)` (nothing to host) and anything else is malformed AST — both route `:skip`.
        _ -> :skip
      end

    [:skip | List.duplicate(clause_treatment, length(rest))]
  end

  def treatments({macro, _meta, args}) when is_atom(macro) and is_list(args) do
    route_macro(Surface.macro_kind(macro), macro, args)
  end

  def treatments(_node), do: []

  defp route_macro(:condition, _name, args) do
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

  defp route_macro(:join, _name, args) do
    args
    |> query_threading_route()
    |> host_join_options(args)
  end

  defp route_macro(:clause, name, args) do
    # No hosted fragment, no shorthand: thread the query (first arg → `:expression` when it is
    # one) and leave the data positions raw for the plugin's own `mutate/2` mutators — except a
    # bound macro's literal-integer value (the **last** argument in the direct and pipe forms
    # alike; a piped call's visible args exclude the threaded query), which routes `:hosted` so
    # the `:bound` bump weaves pin-only. `List.last([])` is `nil`, never a literal integer, so a
    # degenerate `limit()` keeps the empty route.
    base = query_threading_route(args)

    if Surface.bound?(name) and Catalog.bound_literal?(List.last(args)) do
      # mutare:ignore[operand_swap] equivalent — limit/offset are arity-1 (piped) or arity-2 (direct) macros only, and List.replace_at/3's negative index counts from the end, so `1 - length(args)` still lands on the same last element as `length(args) - 1` for both possible arities
      List.replace_at(base, length(args) - 1, :hosted)
    else
      base
    end
  end

  # Only `:dynamic`/`:skip` (registered `:skip`, so core never calls `route_arguments/2` for
  # them — reachable here only through a direct `treatments/1` call) and `nil` (a name the
  # plugin doesn't own) land here. A **new** Surface kind registers `:routing` by default
  # (`Surface.macro_registrations/0`), so it must take a real branch above —
  # `macro_kind_parity_test.exs` probes every `Surface.macro_kinds/0` value and fails until
  # the routing decision for the kind is explicit.
  defp route_macro(_kind, _name, _args), do: []

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
      nil -> qualified_query_builder?(node)
    end
  end

  # An outer routing classifier runs before core descends into its arguments, so a nested qualified
  # macro has no macro-identity stamp yet. Its explicit `Ecto.Query` receiver is nevertheless
  # authoritative through ordinary call resolution; once routed `:expression`, descent stamps and
  # analyzes it normally. Bare query builders are recognized by the clause above.
  defp qualified_query_builder?(node) do
    case Calls.resolved_call_to(node, Ecto.Query) do
      {:ok, name, _args, _rebuild} -> Surface.query_builder?(name)
      :error -> false
    end
  end

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
  # condition value (below); a bound clause (`limit:`/`offset:`) routes `:hosted` iff its value
  # is a literal integer (the pin-only bound bump — an interpolated/expression bound stays raw);
  # every other clause (select/order_by — whole-`from`'s job, or a field-name carrier) is left raw.
  defp clause_treatments(clauses) do
    case KeywordList.parse(clauses) do
      %KeywordList{entries: entries} ->
        Enum.map(entries, fn entry ->
          cond do
            Surface.from_clause?(entry.key, :hosted) -> condition_treatment(entry.value)
            # mutare:ignore[logical] equivalent — even a wrongly-:hosted entry produces no observable weave: `bound_literal?/1` is `Mutare.Ecto.Host.Catalog.bounds/1` non-emptiness, so a pin/expression bound that slipped through yields an empty target list, and a hostable non-bound key is re-gated by `Surface` checks on the host side — the weave is empty regardless of what this routing classification says
            Surface.bound?(entry.key) and Catalog.bound_literal?(entry.value) -> :hosted
            true -> :skip
          end
        end)

      nil ->
        []
    end
  end

  # The treatment for one `where`/`having` condition value. A keyword-shorthand value
  # (`where: [active: true]`) routes its pairs individually; every other value is `:hosted` — the
  # woven `dynamic/2` re-declares the source/join bindings, or an empty list when the source is a
  # bare queryable whose condition references only a named binding
  # (`Mutare.Ecto.Host.Bindings.from/2` builds that list). A top-level interpolation
  # (`where: ^cond`) is `:hosted` too: its own SQL catalog is empty, but the host sub-contracts the
  # pin's interior to core (a pinned Elixir condition's logic is core's to mutate), matching the
  # standalone binding-form and free-standing `dynamic` paths.
  defp condition_treatment(value) do
    case KeywordList.nonempty(value) do
      nil -> :hosted
      pairs -> {:keyword, pair_treatments(pairs)}
    end
  end

  defp pair_treatments(%KeywordList{entries: entries}) do
    Enum.map(entries, &pair_treatment(&1.value))
  end

  # The treatment for one shorthand pair's *value*: a scalar literal (string, number, boolean — but
  # not `nil`) is routed `:interpolated`: core's literal families mutate it, delivered through `^`
  # interpolation (the query position needs the pin). A `nil` (an `IS NULL` predicate, never
  # `= nil`) and any compound/interpolated value are left raw (`:skip`) — interpolation routing is
  # scalar-only, since a compound value would mutate nested nodes where an inner `^` still poisons.
  defp pair_treatment(value) do
    if scalar_literal?(value), do: :interpolated, else: :skip
  end

  # A scalar literal, excluding `nil` — an atom, but an `IS NULL`, not core's to pin. `true`/`false`
  # are atoms too and *are* pinnable; the `not is_nil/1` guard keeps only `nil` out, so the ordering
  # trap of a separate nil check disappears. `literal_value/1` reads the value through Sourceror's
  # wrapper (and a bare scalar), so this owns the nil/kind decision, not the unwrapping.
  defp scalar_literal?(value) do
    case Mutare.AST.literal_value(value) do
      {:ok, v} -> is_binary(v) or is_number(v) or (is_atom(v) and not is_nil(v))
      :error -> false
    end
  end
end
