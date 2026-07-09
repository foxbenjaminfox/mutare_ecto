defmodule Mutare.Ecto.Host do
  @moduledoc """
  Builds selector-host targets for localized Ecto query conditions.

  The companion `Mutare.Ecto.Host.Routing` identifies hosted argument positions. This module then
  coordinates three focused components: `Host.Bindings` interprets Ecto binding declarations,
  `Host.Catalog` produces the logical mutants — the plugin's own SQL catalogs plus the core
  mutants it sub-contracts for each `^` pin island via `Mutare.Analyze.expression_mutations/3`
  (which is why `context` threads down to the catalog) — and `Host.Target` constructs the
  `dynamic/2` wrap and selector splice consumed by Mutare core.

  Besides conditions, the host also weaves the `:bound` ±1 bump of a literal `limit`/`offset`
  value as a **pin-only** target (`limit: ^(case …)` — no `dynamic/2` wrap, no bindings): a bound
  is an integer parameter, so pinning the selector directly is plain Ecto interpolation with a
  behaviorally identical baseline, and the bump never duplicates the whole query the way a
  whole-`from` rewrite would.
  """

  alias Mutare.Ecto.{Config, Surface}
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Bindings, Catalog, JoinOn, Target}
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
          _other -> []
        end

      _ ->
        []
    end
  end

  defp from_targets(source, %KeywordList{entries: entries} = clauses, opts, context) do
    hostable_on = JoinOn.hostable_from_indices(entries)

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      # A bound clause (`limit:`/`offset:`) weaves pin-only — no `dynamic/2` wrap, so no bindings
      # to accumulate; every other entry takes the condition path.
      if Surface.bound?(entry.key) do
        bound_from_target(entry, index)
      else
        # `index + 1` includes the current entry itself in the truncated list handed to
        # `Bindings.from/2` — harmless because a *hostable* key (`where`/`having`/`on`,
        # `Surface.from_clause?(_, :hosted)`) never also carries `:join_binding`, so the current
        # entry never itself contributes a binding; only the join entries *before* it (already
        # included at `index - 1` and below) matter. Dropping to `index + 0` is therefore
        # equivalent given every current descriptor — hence the ignore below — while going the
        # other way (`index + 2`, pulling in a *future* join) is a real bug (see "each join
        # condition sees bindings introduced up to that join, not future joins" in host_test.exs).
        # mutare:ignore[literal:pred] equivalent: the current entry never contributes a binding
        bindings = Bindings.from(source, %{clauses | entries: Enum.take(entries, index + 1)})
        from_target({entry, index}, bindings, {opts, context}, hostable_on)
      end
    end)
  end

  defp bound_from_target(%Entry{value: value}, index) do
    case Catalog.bounds(value) do
      [] -> []
      mutants -> [Target.bound_from_clause(value, mutants, index)]
    end
  end

  defp from_target(
         {%Entry{key: key, value: condition}, index},
         bindings,
         {opts, context},
         hostable_on
       ) do
    # No `bindings` non-emptiness guard: a bare-queryable source (`from("t", as: :t, where:
    # as(:t).x > 1)`) declares no positional binding, so `Bindings.from/2` returns `[]` and the woven
    # `dynamic([], …)` re-declares none — valid, since such a condition can only reference a *named*
    # binding. Hostability is decided by the clause key and a non-empty catalog, not the binding count.
    # A top-level-pin condition (`where: ^cond`) hosts too: its own catalog is empty, but the host
    # sub-contracts the pin's interior to core (`Mutare.Ecto.Host.Catalog.mutants/3`), so the
    # `[_ | _]` guard passes whenever core has something to mutate in that interior.
    with true <- hostable_clause?(key, index, hostable_on),
         true <- Surface.from_clause?(key, :hosted),
         [_ | _] = mutants <- Catalog.mutants(condition, opts, context) do
      [Target.from_clause(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  # `where`/`having` always host (each is its own top-level clause). An `on:` hosts only when it is
  # its join's sole, top-level on-expression — otherwise Ecto folds it under an `and` where a
  # `^dynamic` operand is illegal (`Mutare.Ecto.Host.JoinOn`).
  defp hostable_clause?(:on, index, hostable_on), do: MapSet.member?(hostable_on, index)
  defp hostable_clause?(_key, _index, _hostable_on), do: true

  defp condition_target(args, opts, context) do
    with {bindings, condition, index} <- Bindings.hosted_condition(args),
         [_ | _] = mutants <- Catalog.mutants(condition, opts, context) do
      [Target.condition(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  # A plain clause macro is subscribed only for its bound value (`limit`/`offset` —
  # `Surface.bound?/1`); the bound is the **last argument** in both the direct and pipe forms
  # (the same last-arg convention the clause mutators use). Pin-only: `Catalog.bounds/1` is the
  # single literal-integer guard (the routing classifier consumes it as
  # `Catalog.bound_literal?/1`), so a `^pinned`/expression bound (or a degenerate `limit()`)
  # yields no target and the call degrades safely to raw.
  defp bound_target(macro, [_ | _] = args) do
    with true <- Surface.bound?(macro),
         [_ | _] = mutants <- Catalog.bounds(List.last(args)) do
      # `length(args) - 1` is always the bound's own (last) position, since `limit`/`offset` are
      # arity-1 (piped) or arity-2 (direct) macros — never more. `List.replace_at/3` (which
      # consumes this index in `Target.bound_argument/3`) treats a negative index as counting
      # from the end, so the operand-swapped `1 - length(args)` still lands on the same last
      # element for both possible arities (0 for arity 1, -1 for arity 2) — equivalent given the
      # macros' fixed arity, not a real index bug.
      # mutare:ignore[operand_swap] equivalent: List.replace_at/3's negative index still hits the last element
      [Target.bound_argument(List.last(args), mutants, length(args) - 1)]
    else
      _ -> []
    end
  end

  # Unreachable through `host/2`'s real calling contract: `Host.host/2` is only invoked once
  # `Mutare.Transform.Analyze.Macros.attach_hosted_candidates/5` (core) already found a `:hosted`
  # position via routing — and for a `:clause` macro, routing marks `:hosted` only when
  # `Surface.bound?(macro) and Catalog.bound_literal?(List.last(args))`, which itself requires a
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
    index = length(args) - 1

    case KeywordList.nonempty(List.last(args)) do
      %KeywordList{} = options -> {index, options}
      _ -> nil
    end
  end
end
