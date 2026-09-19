defmodule Mutare.Ecto.Host.Routing do
  @moduledoc """
  Classifies arguments of registered query macros for `c:Mutare.CallRouting.route_arguments/2`.
  Core follows these routes; `Mutare.Ecto.Host` supplies the targets at `:hosted` positions.

  ## Query sources

  The call's form determines **where** its query source is: the first visible argument when
  direct, or `Mutare.CallRouting.Call.pipe_left` when piped. The source's shape then determines
  its treatment, identically for `from` and the composable `where`/`join`/`limit` stages:

    * A schema alias, table-name string (including interpolation), or `{"table", Schema}` pair
      stays `:raw`. Replacing a table/schema name makes a broken query.
    * An `in` binding declaration stays `:raw`. It is syntax the macro consumes, not an Elixir
      expression. This also withholds mutations inside its queryable (`p in build(n + 1)`);
      the host separately reads the declaration through `Mutare.Ecto.Host.Bindings`.
    * A `fragment(...)` source stays `:raw`: its template and arguments are SQL syntax.
    * A `values(rows, types)` source stays `:raw`: its row keys and declared SQL types
      describe the source's structure and must agree.
    * Every other source routes `:expression`: a variable, function call, nested `from`, or
      upstream pipeline. Core keeps its mutations reachable through the enclosing query stage.

  No shape guess locates the source, and no call resolution inside a piped source is needed:
  `pipe_left` contains the source as written, before core resolves its calls.

  ## Query data

    * **`from`** routes its clause list per pair. Expression conditions (`where`/`having`/`on`)
      route `:hosted`; keyword-shorthand conditions route their scalar values `:interpolated`.
      Literal `limit:`/`offset:` values route `:hosted` for the pin-only bound bumps. Other
      clause values stay raw for the whole-`from` producers. `Mutare.Ecto.AST.FromCall` places
      the clauses and reads the source in both spellings. For a piped binding declaration,
      hosting remains available but whole-call rewrites are withheld until core can preserve
      that syntax when delivering a pipe-stage mutant (NOTES "A binding pattern on a pipe's
      left: hosted only").
    * **Composable conditions** locate their condition through `Mutare.Ecto.Host.Condition`.
      A predicate routes `:hosted`; a keyword shorthand routes per pair, exactly as in `from`.
      Written binding lists stay raw.
    * **Plain clauses** (`select`/`order_by`/…) keep their data raw. A literal-integer bound
      (`limit`/`offset`) instead routes `:hosted`, using `Mutare.Ecto.Bound`'s literal-only guard.
    * **`join`** routes its trailing options per pair: `on:` uses the condition classification,
      while `as:`/`prefix:`/`hints:` stay raw.

  A shorthand routes scalar values through `^` interpolation because Ecto rejects a bare
  selector `case` there. Keys, nil values (`IS NULL`, never `= nil`), existing pins and compound
  values stay raw. Those scalar mutants belong to core's producing family, not `:ecto`.
  `Mutare.Ecto.Host.Condition` decides whether a value is a predicate or shorthand once, so
  the host and classifier agree even when a sibling position causes the whole call to be hosted.

  `:hosted` permits the host to consider a position; it does not promise the host will weave
  it. Declaration and receiving-clause constraints remain `Mutare.Ecto.StaticCondition`'s.
  Whole nodes are still offered to the plugin's mutators regardless of their argument routes.

  `dynamic` and `is_named_binding` register `:raw` instead of using this classifier
  (`Mutare.Ecto.Surface.macro_registrations/0`): neither threads a query. A free-standing
  `dynamic` is still offered whole to `Mutare.Ecto.Dynamic`.
  """

  alias Mutare.Ecto.{Bound, Surface}
  alias Mutare.Ecto.AST.{FromCall, KeywordList}
  alias Mutare.Ecto.Host.Condition
  alias Mutare.CallRouting.{ArgumentRoutes, Call}

  @doc """
  Route the visible arguments and, when piped, the source carried in `call.pipe_left`.
  Both source positions use the same shape classifier.
  """
  @spec route_arguments(Call.t(), Mutare.CallRouting.routing_context()) :: ArgumentRoutes.t()
  def route_arguments(%Call{name: name, arguments: args, pipe_left: pipe_left} = call, _context) do
    ArgumentRoutes.from_visible(call, treatments(name, args, pipe_left),
      piped: piped_treatment(pipe_left)
    )
  end

  defp piped_treatment(:unpiped), do: nil
  defp piped_treatment({:piped, source}), do: source_treatment(source)

  @doc """
  Per-visible-argument treatments for a registered query macro. `pipe_left` places the source
  by the call's written form, and supplies its AST when it is outside the visible arguments.
  Returns `[]` for a name the plugin doesn't route.
  """
  @spec treatments(atom(), [Macro.t()], Call.pipe_left()) :: [Mutare.CallRouting.treatment()]
  def treatments(:from, args, pipe_left) do
    clause_treatment =
      case FromCall.parse_args(args, pipe_left) do
        {_source, %KeywordList{} = clauses} -> {:keyword, clause_treatments(clauses)}
        nil -> :raw
      end

    case {pipe_left, args} do
      {:unpiped, [source | rest]} ->
        [source_treatment(source) | List.duplicate(clause_treatment, length(rest))]

      {:unpiped, []} ->
        []

      {{:piped, _source}, visible} ->
        List.duplicate(clause_treatment, length(visible))
    end
  end

  def treatments(macro, args, pipe_left),
    do: route_macro(Surface.macro_kind(macro), macro, args, Call.pipe_mode(pipe_left))

  defp route_macro(:condition, _name, args, pipe_mode) do
    # The threaded query (the first arg, when written directly) is an ordinary expression; its own
    # data positions stay raw. The condition/shorthand overlay then marks what the host/core own.
    base = query_threading_route(args, pipe_mode)

    case Condition.locate(:condition, args, pipe_mode) do
      # A condition, with its declaration written (`where(q, [u], cond)`) or omitted
      # (`where(q, as(:post).x > 1)`). One whose declaration the plugin cannot interpret routes
      # `:hosted` too and the host declines it — hostability is the host's call, as for a
      # non-hostable `on:`.
      %Condition{index: index} -> List.replace_at(base, index, :hosted)
      # keyword-shorthand form (`where(q, col: v)` / `where(q, [p], col: v)`) — route the trailing
      # keyword list per-pair.
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

  # Piped, every visible argument is query data; `route_arguments/2` routes the source
  # separately. Direct, the first argument is the source and the remainder stay raw until
  # the condition/bound/options overlay. Registered :any arities include the empty form.
  defp query_threading_route(args, :piped), do: List.duplicate(:raw, length(args))
  defp query_threading_route([], :unpiped), do: []

  defp query_threading_route([queryable | rest], :unpiped),
    do: [source_treatment(queryable) | List.duplicate(:raw, length(rest))]

  # A query source: an ordinary expression — a variable, a `from(…)`, a nested
  # pipe, a function call, a conditional — whose upstream mutations core reaches by descending
  # it (a bare variable routes `:expression` harmlessly: core finds no candidates on it), unless
  # it is a structural queryable, which stays raw.
  @doc false
  @spec source_treatment(Macro.t()) :: :raw | :expression
  def source_treatment({:in, _meta, [_bindings, _queryable]}), do: :raw
  def source_treatment({:fragment, _meta, args}) when is_list(args), do: :raw
  def source_treatment({:values, _meta, [_rows, _types]}), do: :raw

  def source_treatment(node),
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

  # No predicate located → maybe a keyword filter, written with or without a binding list before
  # it (`where(q, col: v)` / `where(q, [p], col: v)`). Route the trailing argument
  # `{:keyword, value_treatments}` so core mutates each scalar value `^`-pinned, leaving keys and
  # nil/compound values alone. Anything else trailing (a lone binding list, `[]`) → default.
  defp shorthand_route(args, default) do
    case args |> List.last() |> Condition.shape() do
      {:keyword_filter, pairs} -> route_last(default, {:keyword, pair_treatments(pairs)})
      :pairless_list -> default
      # Reached only by an arity the macro does not have — an argless call (`List.last([])` is
      # `nil`, which is no list), a lone `where(q)`: a trailing predicate at a real arity is what
      # `Condition.locate/3` would have located.
      {:predicate, _kind} -> default
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
  # `from` clause (`where:`/`having:`/`on:`) or a standalone `join`'s `on:` option — by the
  # classification the host itself reads (`Mutare.Ecto.Host.Condition.shape/1`), so the two can
  # never disagree about who owns a position: a predicate — a top-level interpolation
  # `where: ^cond` included, whose interior the host sub-contracts to core (`Mutare.Ecto.Island`)
  # — is `:hosted`; a keyword filter (`where: [active: true]`, `on: [views: 5]`) routes its pairs
  # individually; a list with no pair to route (`where: []`) is left raw.
  defp condition_treatment(value) do
    case Condition.shape(value) do
      {:predicate, _kind} -> :hosted
      {:keyword_filter, pairs} -> {:keyword, pair_treatments(pairs)}
      :pairless_list -> :raw
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
