defmodule Mutare.Ecto.Host do
  @moduledoc """
  Builds selector-host targets for localized Ecto query conditions.

  The companion `Mutare.Ecto.Host.Routing` identifies hosted argument positions. This module then
  coordinates four focused components: `Host.Condition` locates the condition argument a
  `where`/`having` call owns (binding-form or binding-less), `Host.Bindings` interprets Ecto
  binding declarations, `Host.Catalog` produces the logical mutants — the plugin's own SQL catalogs plus the mutants
  `Mutare.Ecto.Island` sub-contracts for each `^` pin interior via
  `Mutare.Analyze.expression_mutations/3` (which is why `context` threads down to the catalog) —
  and `Host.Target` constructs the `dynamic/2` wrap and selector splice consumed by Mutare core.

  Besides conditions, the host also weaves the `:bound` ±1 bump of a literal `limit`/`offset`
  value as a **pin-only** target (`limit: ^(case …)` — no `dynamic/2` wrap, no bindings): a bound
  is an integer parameter, so pinning the selector directly is plain Ecto interpolation with a
  behaviorally identical baseline, and the bump never duplicates the whole query the way a
  whole-`from` rewrite would. `Mutare.Ecto.Bound` is the bump catalog and its literal guard.
  """

  alias Mutare.Ecto.{Bound, Config, Surface}
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Bindings, Catalog, Condition, JoinOn, Target}
  alias Mutare.MacroRouting.Call

  @doc """
  `c:Mutare.Mutator.MacroHost.host/2`: the selector-host targets for a resolved Ecto.Query macro
  call. The call's `node` is re-read through `Mutare.Ecto.AST.QueryCall` so the splice transforms
  rebuild the author's written form.
  """
  @spec host(Call.t(), Mutare.Mutator.context()) :: [Target.t()]
  def host(%Call{node: node}, context) do
    config = Config.from_context(context)

    case QueryCall.parse(node) do
      %QueryCall{name: :from, args: [source, clauses]} ->
        case KeywordList.parse(clauses) do
          %KeywordList{} = clauses -> from_targets(source, clauses, config, context)
          nil -> []
        end

      %QueryCall{name: macro, args: args} ->
        case Surface.macro_kind(macro) do
          :condition -> condition_target(args, config, context)
          :join -> join_target(args, config, context)
          :clause -> bound_target(macro, args)
          # Defensively dead: `hosted_macro_names/0` subscribes only `:from` (matched by name
          # above), `:condition`, `:join`, and the bound `:clause` macros, so no other kind is
          # ever offered to `host/2`. `macro_kind_parity_test.exs` probes every
          # `Surface.macro_kinds/0` value — a new kind must take a branch here or stay
          # structurally unsubscribed, never silently weave nothing.
          _other -> []
        end

      _ ->
        []
    end
  end

  defp from_targets(source, %KeywordList{entries: entries} = clauses, config, context) do
    hostable_on = JoinOn.hostable_from_indices(entries)

    KeywordList.flat_map(clauses, fn %Entry{key: key, value: value}, index ->
      cond do
        # A bound clause (`limit:`/`offset:`) weaves pin-only — no `dynamic/2` wrap, so no
        # bindings to accumulate.
        Surface.bound?(key) ->
          bound_from_target(value, index)

        # A hostable condition clause. `Bindings.visible_to/2` owns the truncation offset (and
        # why it includes the current entry itself); each clause sees only the join bindings
        # introduced up to it.
        hostable_clause?(key, index, hostable_on) ->
          bindings = Bindings.from(source, Bindings.visible_to(clauses, index))
          from_target(value, bindings, index, config, context)

        true ->
          []
      end
    end)
  end

  # Whether a `from` clause key's value is a hostable condition: one of the `:hosted` keys
  # (`where`/`having`/`on` — `Mutare.Ecto.Surface`), where `where`/`having` always host (each is
  # its own top-level clause) but an `on:` hosts only when it is its join's sole, top-level
  # on-expression — otherwise Ecto folds it under an `and` where a `^dynamic` operand is illegal
  # (`Mutare.Ecto.Host.JoinOn`).
  defp hostable_clause?(:on, index, hostable_on), do: MapSet.member?(hostable_on, index)
  defp hostable_clause?(key, _index, _hostable_on), do: Surface.from_clause?(key, :hosted)

  defp bound_from_target(value, index) do
    case Bound.bumps(value) do
      [] -> []
      mutants -> [Target.bound_from_clause(value, mutants, index)]
    end
  end

  # No `bindings` non-emptiness guard: a bare-queryable source (`from("t", as: :t, where:
  # as(:t).x > 1)`) declares no positional binding, so `Bindings.from/2` returns `[]` and the woven
  # `dynamic([], …)` re-declares none — valid, since such a condition can only reference a *named*
  # binding. Hostability is decided by the clause key (`hostable_clause?/3`, in the caller) and a
  # non-empty catalog, not the binding count. A top-level-pin condition (`where: ^cond`) hosts
  # too: its own catalog is empty, but the host sub-contracts the pin's interior to core
  # (`Mutare.Ecto.Host.Catalog.mutants/3`), so the non-empty branch is taken whenever core has
  # something to mutate in that interior.
  defp from_target(condition, bindings, index, config, context) do
    case Catalog.mutants(condition, config, context) do
      [] -> []
      mutants -> [Target.from_clause(condition, mutants, bindings, index)]
    end
  end

  # The woven `dynamic/2` re-declares the written binding list — or an empty one for the
  # binding-less form (`bindings: nil`), which `Bindings.declarations/1` renders as `[]`.
  defp condition_target(args, config, context) do
    with %Condition{node: condition, index: index, bindings: list} <- Condition.locate(args),
         [_ | _] = mutants <- Catalog.mutants(condition, config, context) do
      [Target.condition(condition, mutants, Bindings.declarations(list), index)]
    else
      _ -> []
    end
  end

  # A plain clause macro is subscribed only for its bound value (`limit`/`offset` —
  # `Surface.bound?/1`); the bound is the **last argument** in both the direct and pipe forms
  # (the same last-arg convention the clause mutators use). Pin-only: `Bound.bumps/1` is the
  # single literal-integer guard (the routing classifier consumes it as
  # `Bound.literal?/1`), so a `^pinned`/expression bound (or a degenerate `limit()`)
  # yields no target and the call degrades safely to raw.
  defp bound_target(macro, [_ | _] = args) do
    {bound, index} = last_argument(args)

    with true <- Surface.bound?(macro),
         [_ | _] = mutants <- Bound.bumps(bound) do
      [Target.bound_argument(bound, mutants, index)]
    else
      _ -> []
    end
  end

  # Unreachable through `host/2`'s real calling contract: `Host.host/2` is only invoked once
  # `Mutare.Transform.Analyze.Macros.attach_hosted_candidates/5` (core) already found a `:hosted`
  # position via routing — and for a `:clause` macro, routing marks `:hosted` only when
  # `Surface.bound?(macro) and Bound.literal?(List.last(args))`, which itself requires a
  # non-empty `args`. So by the time core calls `bound_target/2`, `args` always matches the
  # `[_ | _]` clause above; this fallback is a defensive totality guard against args ever being
  # `[]` (a degenerate `limit()`), not a reachable branch — kept for safety if that calling
  # contract ever loosens.
  # mutare:ignore[clause_drop] unreachable: core only calls host/2 after routing confirms a non-empty, literal-bound arg list
  defp bound_target(_macro, _args), do: []

  defp join_target(args, config, context) do
    with {arg_index, options} <- trailing_options(args),
         pair_index when not is_nil(pair_index) <-
           Enum.find_index(options.entries, &(&1.key == :on)),
         true <- JoinOn.hostable_standalone?(args, options.entries),
         %Entry{value: condition} = Enum.at(options.entries, pair_index),
         [_ | _] = bindings <- Bindings.join(args),
         [_ | _] = mutants <- Catalog.mutants(condition, config, context) do
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
