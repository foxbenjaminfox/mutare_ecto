defmodule Mutare.Ecto.Host.Target do
  @moduledoc false
  # Builds the host-target map consumed by Mutare core and owns every delivery transform: wrapping
  # logical fragments in `dynamic/2`, pinning the selector, and splicing it into the original call.

  alias Mutare.Ecto.AST
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}

  @type wrap :: (Macro.t() -> Macro.t())
  @type splice :: (Macro.t(), Macro.t() -> Macro.t())
  @type t :: %{
          required(:original) => Macro.t(),
          required(:mutants) => [Mutare.Mutator.mutation()],
          required(:wrap) => wrap(),
          required(:splice) => splice()
        }

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

  defp new(original, mutants, bindings, splice) do
    %{original: original, mutants: mutants, wrap: dynamic_wrap(bindings), splice: splice}
  end

  defp dynamic_wrap(bindings) do
    fn fragment ->
      AST.remote_call(AST.absolute_alias([:Ecto, :Query]), :dynamic, [bindings, fragment])
    end
  end

  defp pin(case_node), do: {:^, [], [case_node]}
end
