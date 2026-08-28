defmodule Mutare.Ecto.Host.Target do
  @moduledoc false
  # Builds the `Mutare.Mutator.MacroHost.Target` values consumed by Mutare core and owns every
  # delivery transform: wrapping logical fragments in `dynamic/2` (the target's `:wrap`), pinning
  # the selector, and splicing it into the original call. The bound-bump targets are **pin-only**
  # (`Mutare.Ecto.Bound`): no `:wrap` (core defaults the branch wrapper to identity, so each
  # branch is a bare integer) and no bindings.

  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
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
  def from_clause(original, mutants, bindings, index),
    do: new(original, mutants, bindings, from_clause_splice(index))

  @doc "A target for a standalone or piped condition macro argument."
  @spec condition(Macro.t(), [Mutare.Mutator.mutation()], [Macro.t()], non_neg_integer()) :: t()
  def condition(original, mutants, bindings, index),
    do: new(original, mutants, bindings, argument_splice(index))

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
        options |> KeywordList.put_value(pair_index, pin(case_node)) |> KeywordList.to_ast()
      )
    end)
  end

  @doc "A pin-only target for a `from` bound clause value (`limit:`/`offset:`) — no wrap, no bindings."
  @spec bound_from_clause(Macro.t(), [Mutare.Mutator.mutation()], non_neg_integer()) :: t()
  def bound_from_clause(original, mutants, index),
    do: MacroHost.Target.new(original, mutants, from_clause_splice(index))

  @doc "The pin-only sibling for a standalone/pipe bound argument (`limit(q, 10)` / `q |> offset(5)`)."
  @spec bound_argument(Macro.t(), [Mutare.Mutator.mutation()], non_neg_integer()) :: t()
  def bound_argument(original, mutants, index),
    do: MacroHost.Target.new(original, mutants, argument_splice(index))

  # The splice that pins the selector into a `from` keyword clause's value at `index` — shared by
  # the `dynamic/2`-wrapped condition target (`from_clause/4`) and the pin-only bound target
  # (`bound_from_clause/3`); only the `:wrap` differs between them.
  defp from_clause_splice(index) do
    fn node, case_node ->
      %FromCall{} = from = FromCall.parse(node)
      from |> FromCall.replace_clause(index, pin(case_node)) |> FromCall.to_ast()
    end
  end

  # The splice that pins the selector into a positional call argument at `index` — shared by the
  # wrapped condition target (`condition/4`) and the pin-only bound target (`bound_argument/3`).
  defp argument_splice(index) do
    fn node, case_node ->
      %QueryCall{} = call = QueryCall.parse(node)
      QueryCall.replace_arg(call, index, pin(case_node))
    end
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
