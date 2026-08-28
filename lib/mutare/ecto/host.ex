defmodule Mutare.Ecto.Host do
  @moduledoc """
  Builds selector-host targets for localized Ecto query conditions.

  The companion `Mutare.Ecto.Host.Routing` identifies hosted argument positions. This module then
  coordinates four focused components: `Host.Condition` locates the condition argument a
  `where`/`having` call owns, `Host.Bindings` interprets Ecto binding declarations, `Host.Catalog`
  produces the logical mutants — the plugin's own SQL catalog plus the pin interiors
  `Mutare.Ecto.Island` sub-contracts to core (which is why `context` threads down to the
  catalog) — and `Host.Target` constructs the `dynamic/2` wrap and selector splice consumed by
  Mutare core.

  Besides conditions, the host also weaves the `:bound` ±1 bump of a literal `limit`/`offset`
  value, as a **pin-only** target with no `dynamic/2` wrap and no bindings — see
  `Mutare.Ecto.Bound`, the bump catalog and its literal guard. In a `from`, only the
  *effective* occurrence of a repeated bound weaves (`Mutare.Ecto.AST.FromCall.effective_clause?/2`).
  """

  alias Mutare.Ecto.{Bound, Context, Surface}
  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Bindings, Catalog, Condition, JoinOn, Target}
  alias Mutare.MacroRouting.Call

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

      %QueryCall{name: macro, args: args} ->
        case Surface.macro_kind(macro) do
          :condition -> condition_target(args, context)
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
    hostable_on = JoinOn.hostable_from_indices(clauses.entries)

    KeywordList.flat_map(clauses, fn %Entry{key: key, value: value}, index ->
      cond do
        # A bound clause (`limit:`/`offset:`) weaves pin-only — no `dynamic/2` wrap, so no
        # bindings to accumulate.
        Surface.bound?(key) ->
          bound_from_target(from, value, index)

        # A hostable condition clause. `Bindings.visible_to/2` owns the truncation offset (and
        # why it includes the current entry itself); each clause sees only the join bindings
        # introduced up to it.
        hostable_clause?(key, index, hostable_on) ->
          bindings = Bindings.from(source, Bindings.visible_to(clauses, index))
          from_target(value, bindings, index, context)

        true ->
          []
      end
    end)
  end

  # Whether a `from` clause key's value is a hostable condition: one of the `:hosted` keys
  # (`Mutare.Ecto.Surface`) — `where`/`having` always, an `on:` only when
  # `Mutare.Ecto.Host.JoinOn` admits it.
  defp hostable_clause?(:on, index, hostable_on), do: MapSet.member?(hostable_on, index)
  defp hostable_clause?(key, _index, _hostable_on), do: Surface.from_clause?(key, :hosted)

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

  # No `bindings` non-emptiness guard: a bare-queryable source (`from("t", as: :t, where:
  # as(:t).x > 1)`) declares no positional binding, so `Bindings.from/2` returns `[]` and the woven
  # `dynamic([], …)` re-declares none — valid, since such a condition can only reference a *named*
  # binding. Hostability is decided by the clause key (`hostable_clause?/3`, in the caller) and a
  # non-empty catalog, not the binding count — so a top-level-pin condition (`where: ^cond`)
  # hosts whenever its sub-contract yields something (`Mutare.Ecto.Island`).
  defp from_target(condition, bindings, index, context) do
    case Catalog.mutants(condition, context) do
      [] -> []
      mutants -> [Target.from_clause(condition, mutants, bindings, index)]
    end
  end

  # The woven `dynamic/2` re-declares the written binding list — or an empty one for the
  # binding-less form (`bindings: nil` — `Mutare.Ecto.Host.Condition`), which
  # `Bindings.declarations/1` renders as `[]`.
  defp condition_target(args, context) do
    with %Condition{node: condition, index: index, bindings: list} <- Condition.locate(args),
         [_ | _] = mutants <- Catalog.mutants(condition, context) do
      [Target.condition(condition, mutants, Bindings.declarations(list), index)]
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
    with {arg_index, options} <- trailing_options(args),
         pair_index when not is_nil(pair_index) <-
           Enum.find_index(options.entries, &(&1.key == :on)),
         true <- JoinOn.hostable_standalone?(args, options.entries),
         %Entry{value: condition} = Enum.at(options.entries, pair_index),
         [_ | _] = bindings <- Bindings.join(args),
         [_ | _] = mutants <- Catalog.mutants(condition, context) do
      [Target.keyword_condition(condition, mutants, bindings, arg_index, pair_index)]
    else
      _ -> []
    end
  end

  defp trailing_options(args) do
    {trailing, index} = last_argument(args)

    case KeywordList.nonempty(trailing) do
      %KeywordList{} = options -> {index, options}
      _ -> nil
    end
  end

  # The trailing argument and its index. A bound value (`limit(q, 10)` / `q |> limit(10)`) and a
  # join's options list sit last in the direct and pipe forms alike — a piped call's visible args
  # exclude the threaded query, so "last" is the one position that holds in both.
  defp last_argument(args), do: {List.last(args), length(args) - 1}
end
