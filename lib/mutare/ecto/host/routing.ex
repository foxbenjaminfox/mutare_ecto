defmodule Mutare.Ecto.Host.Routing do
  @moduledoc """
  The **routing classifier** half of the selector host (`Mutare.Ecto.Host`): the
  `c:Mutare.CallRouting.route_arguments/2` callback that decides, per visible argument of a
  `:routing`-registered query macro, how core should treat that position — `:hosted` (the plugin's
  host weaves it), `:expression` (mutate it normally), `:raw` (leave it raw), `:interpolated`
  (core mutates a scalar value, delivered through `^` interpolation), or `{:keyword, …}` (per-pair
  shorthand routing). `Mutare.Ecto.Host` then consumes the `:hosted` decision to build and weave
  the `^`/`dynamic` target.

  ## Why every query macro routes `:routing`

  The classifier exists so core never splices a runtime selector into a query expression (which
  would poison the single build) **without** losing the upstream query. A composable macro's
  *data* positions (a binding list, an ordering, a selector, a bound) must stay raw — core must
  descend nothing there — but its **threaded query** is an ordinary expression that must stay
  reachable: a static `:raw` registration would stamp the piped value `:raw` and silently drop
  every upstream mutation, so the classifier marks that one position `:expression` and everything
  else raw. A routed node is still offered whole to `mutate/2`, where the plugin's own mutators
  fire (`Mutare.Ecto.Clause`, `Mutare.Ecto.BindingReorder`, `Mutare.Ecto.ClauseDrop`, and
  `Mutare.Ecto.Query` for a `from`).

  ## The threaded query: routed by form, not shape

  *Which* position holds the threaded query is a fact of the call's **form**, which core reports
  as the call's `pipe_mode`, not of any argument's shape. Written directly (`where(q, [p], …)`),
  Ecto's API puts the queryable first; piped (`q |> where([p], …)`), the query is the hidden `|>`
  left side and **no** visible argument is it — every visible argument is the macro's own data.
  So the classifier never guesses whether a first argument "looks like" a query: a computed
  queryable (`where(base_query(2), [p], …)`, an `if`, a `Map.fetch!`) routes `:expression` exactly
  like a bare variable or a nested `from(…)`, and core analyzes its interior as it would anywhere
  else (`base_query(2)`'s `2` → `3`/`1`/`0`). The one shape read in that slot is the **structural
  queryable** — a schema alias (`where(Post, …)`), a table-name string, or a `{"table", Schema}`
  pair — which stays raw: a table/schema swap is a broken query, not a mutant (core's `:alias` and
  `:string` families would otherwise name a nonexistent module or table).

  `dynamic` and the `is_named_binding` guard helper instead register `:raw`
  (`Mutare.Ecto.Surface.macro_registrations/0`): neither is a query-threading stage, so core must
  not descend into their DSL/guard arguments. A `:raw` registration still offers the *whole
  call* to `mutate/2` — which is how a free-standing `dynamic/1,2` is mutated in place
  (`Mutare.Ecto.Dynamic`) while `is_named_binding` stays entirely inert.

  ## The decisions, by call shape

    * the `from` keyword form — `from(p in S, where: p.x == v, …)`: the source is never routed.
      A structural source (`Post`, `"t"`) is a broken query if swapped, and a binding source
      (`p in S`) is a pattern over its queryable that no per-argument treatment can split — so a
      *computed* source (`from(p in base_query(2), …)`) stays raw here too, unlike the threaded
      query of a composable macro (above); its interior earns its mutants where the query is
      built. Each `where`/`having` condition routes by shape, the same under a binding source or a
      bare queryable (`from("t", …)`, whose conditions can only reference a named binding — the
      host weaves them behind an empty-binding `dynamic([], …)`). A non-shorthand *expression*
      condition routes `:hosted`; a keyword-**shorthand** condition (`where: [x: v]`) instead
      routes its pairs individually `{:keyword, …}`: each scalar value `:interpolated` (core's
      literal families mutate it, `^`-pinned — Ecto rejects a bare selector `case` there), while
      the column-name keys, the `nil`-valued pairs (an `IS NULL`, never `= nil`), and compound
      values are left raw. So a shorthand value mutation is recorded under the *core* family that
      made it (`:literal`/`:string`/…), not `:ecto`. The non-condition clauses
      (`select`/`order_by`/… — whole-`from`'s job) are always left raw.
    * the **piped** `from` — `Post |> from(as: :post, where: as(:post).x > v, limit: 5)`: the
      same decisions, placed by form. The source is the hidden `|>` left side, routed `:raw` like
      the direct form's source slot (the plugin never sees its shape, and swapping a structural
      one is a broken query), and the one visible argument is the clause list, routed per clause
      exactly as above — so a bare-queryable pipe hosts its `as(:_)` conditions behind an
      empty-binding `dynamic([], …)`, pins its shorthand values, and weaves its literal bounds.
      `Mutare.Ecto.AST.FromCall` places the clauses by `pipe_mode` for the host and the
      whole-`from` rewrites alike, so the piped and direct spellings yield the same mutants.
    * the composable pipe/standalone form — `q |> where([p], p.x == v)` / `where(q, [p], …)`: the
      threaded query routes `:expression` by form (above), and the condition
      `Mutare.Ecto.Host.Condition` locates (binding-form or binding-less) routes `:hosted`. A
      keyword-shorthand `where(q, x: v)` routes its trailing pairs `{:keyword, …}` as in the
      `from` form. The plain clause macros (`limit`/`order_by`/…) thread the query and leave their
      data positions raw — with one exception: a **literal-integer bound** (`limit(q, 10)` /
      `q |> offset(5)`, and the `limit:`/`offset:` keys of the `from` form) routes `:hosted`, so
      the `:bound` ±1 bump is woven pin-only. The literal-only guard is `Mutare.Ecto.Bound`'s, so
      routing and host agree by definition.
    * the standalone `join/4,5` — `join(q, :inner, [u], p in Post, on: …)`: the threaded query
      routes `:expression` and the trailing **options list routes per-pair**, so its `on:` value
      routes by the same shape rule as the `from` form's (`:hosted` expression condition, per-pair
      `{:keyword, …}` shorthand) and the remaining options (`as:`/`prefix:`/`hints:`) stay raw.

  This relies on core's recursive per-pair routing, hosted values, and `:interpolated` extensions;
  see `c:Mutare.CallRouting.route_arguments/2`.
  """

  alias Mutare.Ecto.{Bound, Surface}
  alias Mutare.Ecto.AST.{FromCall, KeywordList}
  alias Mutare.Ecto.Host.Condition
  alias Mutare.CallRouting.{ArgumentRoutes, Call}

  @doc """
  `c:Mutare.CallRouting.route_arguments/2` for a `:routing`-registered query macro: the
  per-visible-argument `treatments/3` classification, wrapped as `ArgumentRoutes`. Core hands in a
  resolved `Mutare.CallRouting.Call`, so the written form (bare/qualified/aliased/piped) is already
  normalized, and its `pipe_mode` is what places the threaded query (see the moduledoc): a direct
  call's first visible argument is it, while a piped call's hidden left side is — routed
  `:expression` (`from_visible`'s default), so the upstream query stays mutable through the stage.
  The one exception is a piped `from`, whose hidden left side is the never-routed *source*, `:raw`
  (`piped_treatment/1`).
  """
  @spec route_arguments(Call.t(), Mutare.CallRouting.routing_context()) :: ArgumentRoutes.t()
  def route_arguments(%Call{name: name, arguments: args, pipe_mode: pipe_mode} = call, _context) do
    ArgumentRoutes.from_visible(call, treatments(name, args, pipe_mode),
      piped: piped_treatment(name)
    )
  end

  # The treatment of a piped call's hidden left side. For every composable macro it is the
  # threaded query, `:expression` (the moduledoc). For `from` it is the **source**, which is never
  # routed in either form: written directly it is the `:raw` slot below, and piped it is the
  # one position whose shape the classifier cannot even see (core's `Call` carries only the
  # visible arguments) — a structural `Post |> from(…)`, by far the common spelling, would
  # otherwise be handed to core's `:alias` family and swapped for a nonexistent module.
  defp piped_treatment(:from), do: :raw
  defp piped_treatment(_name), do: :expression

  @doc """
  Per-visible-argument treatment for a `:routing`-registered query macro (`from`, the
  `where`/`having` family, `join`, and the plain clause macros), given the resolved macro `name`,
  its visible `args`, and the call's `pipe_mode` — which decides whether the first visible
  argument is the threaded query (see the moduledoc): one entry per argument. Returns `[]` for a
  name the plugin doesn't route.
  """
  @spec treatments(atom(), [Macro.t()], Mutare.Mutator.pipe_mode()) ::
          [Mutare.CallRouting.treatment()]
  def treatments(:from, args, pipe_mode) do
    # The source is never routed (the moduledoc): written directly it is the first visible
    # argument, `:raw`; piped (`Post |> from(…)`) it is the hidden `|>` left side, which
    # `route_arguments/2` routes `:raw` through `piped_treatment/1`, so every visible argument
    # is the clause list. `FromCall.parse_args/2` places the clauses by `pipe_mode`, exactly as
    # the host and the whole-`from` rewrites will; each clause then routes independently
    # (`clause_treatments/1`).
    clause_treatment =
      case FromCall.parse_args(args, pipe_mode) do
        {_source, %KeywordList{} = clauses} -> {:keyword, clause_treatments(clauses)}
        # A non-keyword clause argument (`from(source, ^clauses)`) or malformed AST routes `:raw`.
        # (A clause-less `from(Post)` parses fine but has no clause position to route.)
        nil -> :raw
      end

    case {pipe_mode, args} do
      {:unpiped, [_source | rest]} -> [:raw | List.duplicate(clause_treatment, length(rest))]
      {:unpiped, []} -> []
      {:piped, visible} -> List.duplicate(clause_treatment, length(visible))
    end
  end

  def treatments(macro, args, pipe_mode),
    do: route_macro(Surface.macro_kind(macro), macro, args, pipe_mode)

  defp route_macro(:condition, _name, args, pipe_mode) do
    # The threaded query (the first arg, when written directly) is an ordinary expression; its own
    # data positions stay raw. The condition/shorthand overlay then marks what the host/core own.
    base = query_threading_route(args, pipe_mode)

    case Condition.locate(args) do
      # binding form (`where(q, [u], cond)`) — host the condition after the binding list — or the
      # binding-less form (`where(q, as(:post).x > 1)`) — host the trailing condition itself.
      %Condition{index: index} -> List.replace_at(base, index, :hosted)
      # keyword-shorthand form (`where(q, col: v)`) — route the trailing keyword list per-pair.
      nil -> shorthand_route(args, base)
    end
  end

  defp route_macro(:join, _name, args, pipe_mode) do
    args
    |> query_threading_route(pipe_mode)
    |> route_join_options(args)
  end

  defp route_macro(:clause, name, args, pipe_mode) do
    # No hosted fragment, no shorthand: thread the query and leave the data positions raw —
    # except a bound macro's literal-integer value (the trailing argument — `route_last/2`),
    # which routes `:hosted` for the pin-only bump (`Mutare.Ecto.Bound`). `List.last([])` is
    # `nil`, never a literal integer, so a degenerate `limit()` keeps the empty route.
    base = query_threading_route(args, pipe_mode)

    if Surface.bound?(name) and Bound.literal?(List.last(args)) do
      route_last(base, :hosted)
    else
      base
    end
  end

  # Only `:dynamic`/`:raw` (registered `:raw`, so core never calls `route_arguments/2` for
  # them — reachable here only through a direct `treatments/3` call) and `nil` (a name the
  # plugin doesn't own) land here. A **new** Surface kind must take a real branch above
  # (`Surface.macro_kinds/0`).
  defp route_macro(_kind, _name, _args, _pipe_mode), do: []

  # The base routing for a query-threading macro: every visible position raw (`:raw`) except
  # the threaded query, which routes `:expression`. Which position that is follows the call's
  # form, not any argument's shape (the moduledoc): piped, no visible argument is the query (the
  # `|>` left side is, routed `:expression` by `route_arguments/2` through `from_visible`'s
  # default); written directly, the first argument is — unless it is a structural queryable. An
  # argless call (`q |> limit()`) has no first argument, and core still routes it (the macro
  # registers with `:any` arity), so the empty route keeps this total — `host_test.exs`'s
  # totality case pins it.
  defp query_threading_route(args, :piped), do: List.duplicate(:raw, length(args))
  defp query_threading_route([], :unpiped), do: []

  defp query_threading_route([queryable | rest], :unpiped),
    do: [queryable_treatment(queryable) | List.duplicate(:raw, length(rest))]

  # The directly written queryable: an ordinary expression — a variable, a `from(…)`, a nested
  # pipe, a function call, a conditional — whose upstream mutations core reaches by descending
  # it (a bare variable routes `:expression` harmlessly: core finds no candidates on it), unless
  # it is a structural queryable, which stays raw.
  defp queryable_treatment(node),
    do: if(structural_queryable?(node), do: :raw, else: :expression)

  # An `Ecto.Queryable` written as a table/schema *name* rather than computed: a schema alias
  # (`Post` — core's `:alias` family would swap it for a nonexistent module), a table-name string
  # (`"posts"`, plain or interpolated — core's `:string` family would name a nonexistent table),
  # or the `{"table", Schema}` pair. Read through Sourceror's literal wrapper: a string/tuple
  # literal is block-wrapped, an alias is not.
  defp structural_queryable?(node) do
    case Mutare.AST.unwrap_literal(node) do
      {:__aliases__, _meta, _segments} -> true
      {_table, _schema} -> true
      value -> is_binary(value) or Mutare.AST.string_binary?(value)
    end
  end

  # A standalone `join/4,5`'s trailing options list (`on:`, plus the DSL data keys `as:`/`prefix:`/
  # `hints:`) routes **per-pair**, exactly as the `from` form's clause list does: only the `on:`
  # value carries a condition, and it routes by shape through the same `condition_treatment/1` —
  # `:hosted` for an expression condition (nested `:hosted` is delivered to `host/2` like any
  # other), per-pair `{:keyword, …}` for the keyword shorthand (`on: [views: 5]`), whose scalar
  # values core then mutates `^`-pinned. Routing the whole list `:hosted` instead would leave a
  # shorthand `on:` unmutated in every family: the host's catalog reads SQL conditions, not keyword
  # pairs, so it produces nothing there, while the `:hosted` mark keeps core out.
  #
  # Hostability is *not* re-decided here — a non-hostable `on:` (a multi-`on:` or `assoc` join,
  # `Mutare.Ecto.Host.JoinOn`) still routes `:hosted` and the host declines it, as in the `from`
  # form. A trailing argument that is no keyword list (`join(q, :inner, [u], p in Post)`) keeps the
  # base routing.
  defp route_join_options(routing, args) do
    case args |> List.last() |> KeywordList.nonempty() do
      %KeywordList{entries: entries} ->
        route_last(routing, {:keyword, Enum.map(entries, &join_option_treatment/1)})

      nil ->
        routing
    end
  end

  # One join option's treatment: `on:` is the condition (routed by shape); every other option names
  # DSL data (`as: :post`, `prefix: "x"`, `hints:`) and stays raw.
  defp join_option_treatment(entry) do
    if entry.key == :on, do: condition_treatment(entry.value), else: :raw
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
        # Even a wrongly-`:hosted` entry weaves nothing: `Bound.literal?/1` is `Bound.bumps/1`
        # non-emptiness, so a pin/expression bound that slipped through yields an empty target
        # list, and a hostable non-bound key is re-gated by `Surface` on the host side. An
        # *overridden* bound (`limit: 5, limit: 10`'s `5`) likewise routes `:hosted` by shape and
        # is declined by the host (`FromCall.effective_clause?/2`) — like a non-hostable `on:`,
        # hostability is not re-decided here.
        # mutare:ignore[logical] equivalent — see above
        Surface.bound?(entry.key) and Bound.literal?(entry.value) -> :hosted
        true -> :raw
      end
    end)
  end

  # The treatment for one condition value, wherever a condition is written as a keyword value — a
  # `from` clause (`where:`/`having:`/`on:`) or a standalone `join`'s `on:` option: a
  # keyword-shorthand value (`where: [active: true]`, `on: [views: 5]`) routes its pairs
  # individually; every other value — a top-level interpolation `where: ^cond` included, whose
  # interior the host sub-contracts to core (`Mutare.Ecto.Island`) — is `:hosted`.
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
  # `= nil`) and any compound/interpolated value are left raw (`:raw`) — interpolation routing is
  # scalar-only, since a compound value would mutate nested nodes where an inner `^` still poisons.
  defp pair_treatment(value) do
    if scalar_literal?(value), do: :interpolated, else: :raw
  end

  # A scalar literal, excluding `nil` — an atom, but an `IS NULL`, not core's to pin. `true`/`false`
  # are atoms too and *are* pinnable. `literal_value/1` reads the value through Sourceror's wrapper
  # (and a bare scalar) and yields only numbers, binaries, and atoms — its own clauses admit
  # nothing else — so once `nil` is out, every hit is a pinnable scalar. (Spelling the kinds out
  # again is what Elixir 1.20's type checker flags as a test that always succeeds.)
  defp scalar_literal?(value) do
    case Mutare.AST.literal_value(value) do
      {:ok, nil} -> false
      {:ok, _scalar} -> true
      :error -> false
    end
  end
end
