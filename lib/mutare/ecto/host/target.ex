defmodule Mutare.Ecto.Host.Target do
  @moduledoc false
  # Builds the `Mutare.Mutator.MacroHost.Target` values consumed by Mutare core and owns every
  # delivery transform: wrapping logical fragments in `dynamic/2` (the target's `:wrap`), pinning
  # the selector, and splicing it into the original call. The bound-bump targets are **pin-only**:
  # no `:wrap` (core defaults the branch wrapper to identity, so each branch is a bare integer)
  # and no bindings — the woven selector is plain Ecto interpolation, `limit: ^(case …)`.

  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Mutator.MacroHost

  @type t :: MacroHost.Target.t()

  @doc "A target for one condition in a `from` keyword clause."
  @spec from_clause(
          Macro.t(),
          [Mutare.Mutator.mutation()],
          [Macro.t()],
          non_neg_integer()
        ) ::
          t()
  def from_clause(original, mutants, bindings, index) do
    new(original, mutants, bindings, fn node, case_node ->
      %QueryCall{name: :from, args: [source, clauses]} = call = QueryCall.parse(node)
      clauses = KeywordList.parse(clauses)
      QueryCall.rebuild(call, [source, KeywordList.replace_value(clauses, index, pin(case_node))])
    end)
  end

  @doc "A target for a standalone or piped condition macro argument."
  @spec condition(Macro.t(), [Mutare.Mutator.mutation()], [Macro.t()], non_neg_integer()) :: t()
  def condition(original, mutants, bindings, index) do
    new(original, mutants, bindings, fn node, case_node ->
      %QueryCall{} = call = QueryCall.parse(node)
      QueryCall.replace_arg(call, index, pin(case_node))
    end)
  end

  @doc "A target nested under one keyword option in a standalone query macro."
  @spec keyword_condition(
          Macro.t(),
          [Mutare.Mutator.mutation()],
          [Macro.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def keyword_condition(original, mutants, bindings, arg_index, pair_index) do
    new(original, mutants, bindings, fn node, case_node ->
      %QueryCall{args: args} = call = QueryCall.parse(node)
      options = args |> Enum.at(arg_index) |> KeywordList.parse()

      QueryCall.replace_arg(
        call,
        arg_index,
        KeywordList.replace_value(options, pair_index, pin(case_node))
      )
    end)
  end

  @doc """
  A pin-only target for a `from` bound clause value (`limit:`/`offset:`). No `dynamic/2` wrap and
  no bindings: a bound is an integer parameter, so the selector interpolates directly —
  `limit: ^(case …)` — and each branch is the bare bumped integer.
  """
  @spec bound_from_clause(Macro.t(), [Mutare.Mutator.mutation()], non_neg_integer()) :: t()
  def bound_from_clause(original, mutants, index) do
    MacroHost.Target.new(original, mutants, fn node, case_node ->
      %QueryCall{name: :from, args: [source, clauses]} = call = QueryCall.parse(node)
      clauses = KeywordList.parse(clauses)
      QueryCall.rebuild(call, [source, KeywordList.replace_value(clauses, index, pin(case_node))])
    end)
  end

  @doc "The pin-only sibling for a standalone/pipe bound argument (`limit(q, 10)` / `q |> offset(5)`)."
  @spec bound_argument(Macro.t(), [Mutare.Mutator.mutation()], non_neg_integer()) :: t()
  def bound_argument(original, mutants, index) do
    MacroHost.Target.new(original, mutants, fn node, case_node ->
      %QueryCall{} = call = QueryCall.parse(node)
      QueryCall.replace_arg(call, index, pin(case_node))
    end)
  end

  defp new(original, mutants, bindings, splice) do
    MacroHost.Target.new(original, mutants, splice, wrap: dynamic_wrap(bindings))
  end

  defp dynamic_wrap(bindings) do
    fn fragment ->
      Mutare.AST.absolute_call([:Ecto, :Query], :dynamic, [bindings, fragment])
    end
  end

  defp pin(case_node), do: {:^, [], [case_node]}
end
