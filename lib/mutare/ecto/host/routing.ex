defmodule Mutare.Ecto.Host.Routing do
  @moduledoc """
  The **routing classifier** half of the selector host (`Mutare.Ecto.Host`): the
  `c:Mutare.MacroRouting.route_arguments/2` callback that decides, per visible argument of a
  `:routing`-registered query macro, how core should treat that position — `:hosted` (the plugin's
  host weaves it), `:expression` (mutate it normally), `:skip` (leave it raw), `:interpolated`
  (core mutates a scalar value, delivered through `^` interpolation), or `{:keyword, …}` (per-pair
  shorthand routing). `Mutare.Ecto.Host` then consumes the `:hosted` decision to build and weave
  the `^`/`dynamic` target.

  ## Why every query macro routes `:routing`

  The classifier exists so core never splices a runtime selector into a query expression (which
  would poison the single build) **without** losing the upstream query. A composable macro's
  *data* positions (a binding list, an ordering, a selector, a bound) must stay raw — core must
  descend nothing there — but its **threaded query** (the first argument, or the piped left side)
  is an ordinary expression that must stay reachable: a static `:skip` registration would stamp
  the piped value `:skip` and silently drop every upstream mutation, so the classifier marks that
  one position `:expression` and everything else raw. A routed node is still offered whole to
  `mutate/2`, where the plugin's own mutators fire (`Mutare.Ecto.Clause`,
  `Mutare.Ecto.BindingReorder`, `Mutare.Ecto.ClauseDrop`, and `Mutare.Ecto.Query` for a `from`).

  `dynamic` and the `is_named_binding` guard helper instead register `:skip`
  (`Mutare.Ecto.Surface.macro_registrations/0`): neither is a query-threading stage, so core must
  not descend into their DSL/guard arguments. A `:skip` registration still offers the *whole
  call* to `mutate/2` — which is how a free-standing `dynamic/1,2` is mutated in place
  (`Mutare.Ecto.Dynamic`) while `is_named_binding` stays entirely inert.

  ## The decisions, by call shape

    * the `from` keyword form — `from(p in S, where: p.x == v, …)`: the source is never mutated
      (a table/schema swap is a broken query, not a mutant). Each `where`/`having` condition
      routes by shape, the same under a binding source (`p in S`) or a bare queryable
      (`from("t", …)`, whose conditions can only reference a named binding — the host weaves them
      behind an empty-binding `dynamic([], …)`). A non-shorthand *expression* condition routes
      `:hosted`; a keyword-**shorthand** condition (`where: [x: v]`) instead routes its pairs
      individually `{:keyword, …}`: each scalar value `:interpolated` (core's literal families
      mutate it, `^`-pinned — Ecto rejects a bare selector `case` there), while the column-name
      keys, the `nil`-valued pairs (an `IS NULL`, never `= nil`), and compound values are left raw.
      So a shorthand value mutation is recorded under the *core* family that made it
      (`:literal`/`:string`/…), not `:ecto`. The non-condition clauses (`select`/`order_by`/… —
      whole-`from`'s job) are always left raw.
    * the composable pipe/standalone form — `q |> where([p], p.x == v)` / `where(q, [p], …)`: the
      threaded query routes `:expression` as above, and the condition
      `Mutare.Ecto.Host.Condition` locates (binding-form or binding-less) routes `:hosted`. A
      keyword-shorthand `where(q, x: v)` routes its trailing pairs `{:keyword, …}` as in the
      `from` form. The plain clause macros (`limit`/`order_by`/…) thread the query and leave their
      data positions raw — with one exception: a **literal-integer bound** (`limit(q, 10)` /
      `q |> offset(5)`, and the `limit:`/`offset:` keys of the `from` form) routes `:hosted`, so
      the `:bound` ±1 bump is woven pin-only. The literal-only guard is `Mutare.Ecto.Bound`'s, so
      routing and host agree by definition.

  This relies on core's recursive per-pair routing, hosted values, and `:interpolated` extensions;
  see `c:Mutare.MacroRouting.route_arguments/2`.
  """

  alias Mutare.Ecto.{Binding, Bound, Surface}
  alias Mutare.Ecto.AST.{FromCall, KeywordList}
  alias Mutare.Ecto.Host.Condition
  alias Mutare.Calls
  alias Mutare.MacroRouting.{ArgumentRoutes, Call}

  @doc """
  `c:Mutare.MacroRouting.route_arguments/2` for a `:routing`-registered query macro: the
  per-visible-argument `treatments/2` classification, wrapped as `ArgumentRoutes`. Core hands in a
  resolved `Mutare.MacroRouting.Call`, so the written form (bare/qualified/aliased/piped) is already
  normalized. A piped call's hidden left side is the threaded query, so it keeps `from_visible`'s
  `:expression` default — the upstream query stays mutable through the stage.
  """
  @spec route_arguments(Call.t(), Mutare.MacroRouting.routing_context()) :: ArgumentRoutes.t()
  def route_arguments(%Call{name: name, arguments: args} = call, _context) do
    ArgumentRoutes.from_visible(call, treatments(name, args))
  end

  @doc """
  Per-visible-argument treatment for a `:routing`-registered query macro (`from`, the
  `where`/`having` family, `join`, and the plain clause macros), given the resolved macro `name`
  and its visible `args`: one entry per argument. Returns `[]` for a name the plugin doesn't route.
  """
  @spec treatments(atom(), [Macro.t()]) :: [Mutare.MacroRouting.treatment()]
  def treatments(:from, [_source | rest] = args) do
    # The source is `:skip`; each clause routes independently (`clause_treatments/1`).
    clause_treatment =
      case FromCall.parse_args(args) do
        {_source, %KeywordList{} = clauses} -> {:keyword, clause_treatments(clauses)}
        # A non-keyword clause argument (`from(source, ^clauses)`) or malformed AST routes `:skip`.
        # (A clause-less `from(Post)` parses fine but has no clause position to route.)
        nil -> :skip
      end

    [:skip | List.duplicate(clause_treatment, length(rest))]
  end

  def treatments(macro, args), do: route_macro(Surface.macro_kind(macro), macro, args)

  defp route_macro(:condition, _name, args) do
    # The threaded query (the first arg, when written directly) is an ordinary expression; its own
    # data positions stay raw. The condition/shorthand overlay then marks what the host/core own.
    base = query_threading_route(args)

    case Condition.locate(args) do
      # binding form (`where(q, [u], cond)`) — host the condition after the binding list — or the
      # binding-less form (`where(q, as(:post).x > 1)`) — host the trailing condition itself.
      %Condition{index: index} -> List.replace_at(base, index, :hosted)
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
    # No hosted fragment, no shorthand: thread the query and leave the data positions raw —
    # except a bound macro's literal-integer value (the trailing argument — `route_last/2`),
    # which routes `:hosted` for the pin-only bump (`Mutare.Ecto.Bound`). `List.last([])` is
    # `nil`, never a literal integer, so a degenerate `limit()` keeps the empty route.
    base = query_threading_route(args)

    if Surface.bound?(name) and Bound.literal?(List.last(args)) do
      route_last(base, :hosted)
    else
      base
    end
  end

  # Only `:dynamic`/`:skip` (registered `:skip`, so core never calls `route_arguments/2` for
  # them — reachable here only through a direct `treatments/2` call) and `nil` (a name the
  # plugin doesn't own) land here. A **new** Surface kind must take a real branch above
  # (`Surface.macro_kinds/0`).
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

  # Whether a first-argument node is a query expression that should remain reachable: a nested
  # pipe, a bare variable (`q`), or a nested query-builder call (`from(…)`, `where(…)`, …). A
  # binding list, keyword list, literal, or other DSL-data shape is not — that is a piped call's
  # own first data argument (the threaded query is the `|>` left side, routed separately).
  defp query_arg?({:|>, _meta, _args}), do: true
  defp query_arg?(node), do: Binding.variable?(node) or query_builder_call?(node)

  # A bare call is a query builder by **name** — no stamp consulted, so it holds for a nested
  # call the resolve pass hasn't reached yet (an outer classifier runs before core descends into
  # its arguments) and a false positive (a local `from/2`) only routes `:expression`, core's
  # ordinary treatment. A qualified call (`Ecto.Query.where(…)`) resolves through its explicit
  # receiver, which ordinary call resolution reads stamp or not; once routed `:expression`,
  # descent stamps and analyzes it normally. The name must be registered either way:
  # `Ecto.Query.exclude/2` resolves to the module but is no query builder.
  defp query_builder_call?({name, _meta, args}) when is_atom(name) and is_list(args),
    do: Surface.query_builder?(name)

  defp query_builder_call?(node) do
    case Calls.resolved_call_to(node, Ecto.Query) do
      {:ok, name, _args, _rebuild} -> Surface.query_builder?(name)
      :error -> false
    end
  end

  defp host_join_options(routing, args) do
    with %KeywordList{entries: entries} <- KeywordList.nonempty(List.last(args)),
         true <- Enum.any?(entries, &(&1.key == :on)) do
      route_last(routing, :hosted)
    else
      _ -> routing
    end
  end

  # Overlay `treatment` on the trailing argument's slot. Every overlay the classifier places
  # outside a condition position sits last in the direct and pipe forms alike — the bound
  # value, the join options, the shorthand pairs (a piped call's visible args exclude the
  # threaded query, so "last" is the one index that holds in both) — and `routes` carries one
  # slot per argument, so the last slot is that argument's.
  defp route_last(routes, treatment), do: List.replace_at(routes, -1, treatment)

  # === keyword-shorthand routing =============================================

  # No binding list → maybe a keyword-shorthand condition (`where(q, col: v)`). Route the trailing
  # keyword-list argument `{:keyword, value_treatments}` so core mutates each scalar value
  # `^`-pinned, leaving keys and nil/compound values alone. A non-shorthand trailing arg → default.
  defp shorthand_route(args, default) do
    case args |> List.last() |> KeywordList.nonempty() do
      nil -> default
      pairs -> route_last(default, {:keyword, pair_treatments(pairs)})
    end
  end

  # A `from`'s clause list, one treatment per clause: a `where`/`having` clause routes by its
  # condition value (below); a bound clause (`limit:`/`offset:`) routes `:hosted` iff its value
  # is a literal integer (the pin-only bound bump — an interpolated/expression bound stays raw);
  # every other clause (select/order_by — whole-`from`'s job, or a field-name carrier) is left raw.
  defp clause_treatments(%KeywordList{entries: entries}) do
    Enum.map(entries, fn entry ->
      cond do
        Surface.from_clause?(entry.key, :hosted) -> condition_treatment(entry.value)
        # mutare:ignore[logical] equivalent — even a wrongly-:hosted entry produces no observable weave: `Bound.literal?/1` is `Mutare.Ecto.Bound.bumps/1` non-emptiness, so a pin/expression bound that slipped through yields an empty target list, and a hostable non-bound key is re-gated by `Surface` checks on the host side — the weave is empty regardless of what this routing classification says
        Surface.bound?(entry.key) and Bound.literal?(entry.value) -> :hosted
        true -> :skip
      end
    end)
  end

  # The treatment for one `where`/`having` condition value: a keyword-shorthand value
  # (`where: [active: true]`) routes its pairs individually; every other value — a top-level
  # interpolation `where: ^cond` included, whose interior the host sub-contracts to core
  # (`Mutare.Ecto.Island`) — is `:hosted`.
  defp condition_treatment(value) do
    case KeywordList.nonempty(value) do
      nil -> :hosted
      pairs -> {:keyword, pair_treatments(pairs)}
    end
  end

  # The written-shorthand application of the condition-position keyword rule: a pair's **key
  # names a column** (left raw by the per-pair routing itself), only its value routes. The same
  # rule's *pin-side* application — a keyword filter interior a pin computes, where no call
  # shape exists to route — lives in `Mutare.Ecto.Island.subcontracted/3`'s key-set guard.
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
