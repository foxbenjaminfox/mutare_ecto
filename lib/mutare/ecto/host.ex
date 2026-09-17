defmodule Mutare.Ecto.Host do
  @moduledoc """
  Builds selector-host targets for localized Ecto query conditions.

  The companion `Mutare.Ecto.Host.Routing` identifies hosted argument positions. This module then
  coordinates four focused components: `Host.Condition` locates the condition argument a
  `where`/`having` call contains, `Host.Bindings` interprets Ecto binding declarations, `Host.Catalog`
  produces the logical mutants — the plugin's own SQL catalog plus the pin interiors
  `Mutare.Ecto.Island` passes to core (which is why `context` is passed down to the
  catalog) — and `Host.Target` constructs the `dynamic/2` wrap and selector splice consumed by
  Mutare core.

  The host builds a condition target for a **predicate** only. Core offers the *whole call* as
  soon as any one position routed `:hosted`, and does not confine the returned targets to those
  positions — so a `from`'s hosted `limit:` brings a sibling `where: [score: 5]` here too. That
  sibling is a keyword filter, which the classifier already gave to core pair by pair, and
  which `dynamic/2` would refuse. The host therefore reads every condition value through the
  same classification the classifier used (`Mutare.Ecto.Host.Condition.shape/1`), wherever the
  value is written: a `from` clause, a condition macro's argument, a join's `on:` option —
  `Host.Condition` locates each of the three for a predicate only. Neither the predicate catalog
  nor the pin sub-contract is offered a keyword filter, so hosting a *sibling* never changes
  what happens to it.

  A condition that is itself a `^` pin (`where: ^filters`, `where(q, ^cond)`, a join's `on: ^cond` —
  a predicate of kind `:root_pin`, by the same classification) is woven **pin-only**, over its bare
  interior: Ecto treats such a root interpolation according to its runtime value — a keyword list is
  a field filter, a boolean a literal condition, a dynamic is expanded — and a `dynamic/2` wrap
  would turn the first two into plain parameters. Pinning the selector alone hands Ecto the same
  kind of value the written pin did, so the instrumented query behaves as the original.

  Besides conditions, the host also weaves the `:bound` ±1 bump of a literal `limit`/`offset`
  value, as a **pin-only** target with no `dynamic/2` wrap and no bindings — see
  `Mutare.Ecto.Bound`, the bump catalog and its literal guard. In a `from`, only the
  *effective* occurrence of a repeated bound weaves (`Mutare.Ecto.AST.FromCall.effective_clause?/2`).

  A condition the host cannot weave — a subquery in a `having`, which Ecto accepts only
  statically built, or a condition under a binding declaration the plugin cannot re-declare — is
  delivered as a whole-call rebuild instead, by `Mutare.Ecto.StaticCondition` — whose
  `delivery/3` decides, for the host and the rebuild alike, which conditions those are.
  """

  alias Mutare.Ecto.{Bound, Context, StaticCondition, Surface}
  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Bindings, Catalog, Condition, Target}
  alias Mutare.CallRouting.Call

  @doc """
  `c:Mutare.Mutator.MacroHost.host/2`: the selector-host targets for a resolved Ecto.Query macro
  call. The call's `node` is re-read through `Mutare.Ecto.AST.QueryCall` so the splice transforms
  rebuild the author's written form. Core's `context` is unpacked once here, into the plugin's
  `%Mutare.Ecto.Context{}` — this is the hosted path's core boundary, as
  `Mutare.Ecto.Dispatcher.mutations/2` is the `mutate/2` path's.
  """
  @spec host(Call.t(), Mutare.Mutator.context()) :: [Target.t()]
  def host(%Call{node: node}, context) do
    context = Context.new(context)

    case QueryCall.parse(node) do
      %QueryCall{name: :from} = call ->
        from_targets(FromCall.parse(call), context)

      %QueryCall{name: macro, args: args, pipe_mode: pipe_mode} ->
        case Surface.macro_kind(macro) do
          :condition -> condition_target(macro, args, pipe_mode, context)
          :join -> join_target(args, context)
          :clause -> bound_target(macro, args)
          # Defensively dead: `hosted_macro_names/0` subscribes only the kinds above. A new kind
          # must take a branch here or stay unsubscribed (`Surface.macro_kinds/0`).
          _other -> []
        end

      _ ->
        []
    end
  end

  # A `from` whose second argument isn't a keyword clause list (`from(p in Post, ^clauses)`) has
  # no clause to host.
  defp from_targets(nil, _context), do: []

  defp from_targets(%FromCall{source: source, clauses: clauses} = from, context) do
    conditions = Condition.from_indices(clauses)

    KeywordList.flat_map(clauses, fn %Entry{key: key, value: value}, index ->
      cond do
        # A bound clause (`limit:`/`offset:`) weaves pin-only — no `dynamic/2` wrap, so no
        # bindings to accumulate.
        Surface.bound?(key) ->
          bound_from_target(from, value, index)

        # A hosted predicate clause (`Condition.from_indices/1`, which reports its kind).
        # `Bindings.visible_to/2` owns the truncation offset (and why it includes the current
        # entry itself); each clause sees only the join bindings introduced up to it.
        Map.has_key?(conditions, index) ->
          bindings = Bindings.from(source, Bindings.visible_to(clauses, index))
          from_target(key, value, Map.fetch!(conditions, index), bindings, index, context)

        true ->
          []
      end
    end)
  end

  # A bound weaves at its *effective* occurrence only: one a later same-key clause overrides
  # (`limit: 5, limit: 10`'s `5`) never reaches the query, so its bump would be equivalent
  # (`FromCall.effective_clause?/2`). It routed `:hosted` by shape and is declined here, exactly
  # as a non-hostable `on:` is — hostability is the host's call, not the classifier's.
  defp bound_from_target(from, value, index) do
    with true <- FromCall.effective_clause?(from, index),
         [_ | _] = mutants <- Bound.bumps(value) do
      [Target.bound_from_clause(value, mutants, index)]
    else
      _ -> []
    end
  end

  # Every condition target weaves only what `StaticCondition.delivery/3` assigns it; a
  # `:rebuilt` condition — one the clause cannot take as a dynamic, or one whose declaration
  # `Bindings` cannot re-declare — is `Mutare.Ecto.StaticCondition`'s, delivered whole-call.
  #
  # No `bindings` non-emptiness guard: a bare-queryable source (`from("t", as: :t, where:
  # as(:t).x > 1)`) declares no positional binding, so `Bindings.from/2` returns `{:ok, []}` and
  # the woven `dynamic([], …)` re-declares none — valid, since such a condition can only reference
  # a *named* binding. Hostability is decided by the clause (`Condition.from_indices/1`, in the
  # caller), the delivery, and a non-empty catalog, not the binding count — so a top-level-pin
  # condition (`where: ^cond`) hosts whenever its sub-contract yields something
  # (`Mutare.Ecto.Island`); its weave is pin-only and leaves these bindings unused
  # (`Mutare.Ecto.Host.Target`).
  defp from_target(key, condition, kind, bindings, index, context) do
    with {:woven, bindings} <- StaticCondition.delivery(key, condition, bindings),
         [_ | _] = mutants <- Catalog.mutants(condition, context) do
      [Target.from_clause(condition, kind, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  # The woven `dynamic/2` re-declares the written binding list — or an empty one when none was
  # written (`Mutare.Ecto.Host.Condition`'s three outcomes; the third, uninterpretable, is
  # rebuilt instead).
  defp condition_target(macro, args, pipe_mode, context) do
    with %Condition{node: condition, index: index, kind: kind, declaration: declaration} <-
           Condition.locate(:condition, args, pipe_mode),
         {:woven, bindings} <-
           StaticCondition.delivery(macro, condition, Bindings.declarations(declaration)),
         [_ | _] = mutants <- Catalog.mutants(condition, context) do
      [Target.condition(condition, kind, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  # A plain clause macro is subscribed only for its bound value (`limit`/`offset` —
  # `Surface.bound?/1`); the bound is the **last argument** in both the direct and pipe forms
  # (the same last-arg convention the clause mutators use). `Bound.bumps/1` is the single
  # literal-integer guard (`Mutare.Ecto.Bound`), so a `^pinned`/expression bound yields no target
  # and the call degrades safely to raw. The same guard keeps this total without a fallback clause:
  # a degenerate `limit()` has `last_argument([]) == {nil, -1}`, no literal, so it yields no target
  # the same way (routing never marks it `:hosted` to begin with — `host_test.exs`'s totality case
  # pins that).
  defp bound_target(macro, args) do
    {bound, index} = last_argument(args)

    with true <- Surface.bound?(macro),
         [_ | _] = mutants <- Bound.bumps(bound) do
      [Target.bound_argument(bound, mutants, index)]
    else
      _ -> []
    end
  end

  defp join_target(args, context) do
    with {condition, kind, arg_index, pair_index} <- Condition.locate_on(args),
         {:woven, bindings} <- StaticCondition.delivery(:on, condition, Bindings.join(args)),
         [_ | _] = mutants <- Catalog.mutants(condition, context) do
      [Target.keyword_condition(condition, kind, mutants, bindings, arg_index, pair_index)]
    else
      _ -> []
    end
  end

  # The trailing argument and its index. A bound value (`limit(q, 10)` / `q |> limit(10)`) sits
  # last in the direct and pipe forms alike — a piped call's visible args exclude the threaded
  # query, so "last" is the one position that holds in both.
  defp last_argument(args), do: {List.last(args), length(args) - 1}
end
