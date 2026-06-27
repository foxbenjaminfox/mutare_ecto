defmodule Mutare.Ecto.Host.Target do
  @moduledoc false
  # Builds the host-target map consumed by Mutare core and owns every delivery transform: wrapping
  # logical fragments in `dynamic/2`, pinning the selector, and splicing it into the original call.

  alias Mutare.Ecto.{AST, Pair}

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
          non_neg_integer(),
          tuple()
        ) ::
          t()
  def from_clause(original, mutants, bindings, index, key) do
    new(original, mutants, bindings, fn node, case_node ->
      {:from, [source, clauses], rebuild} = AST.query_macro_call(node)
      rebuild.(:from, [source, List.replace_at(clauses, index, {key, pin(case_node)})])
    end)
  end

  @doc "A target for a standalone or piped condition macro argument."
  @spec condition(Macro.t(), [Mutare.Mutator.mutation()], [Macro.t()], non_neg_integer()) :: t()
  def condition(original, mutants, bindings, index) do
    new(original, mutants, bindings, fn node, case_node ->
      {name, args, rebuild} = AST.query_macro_call(node)
      rebuild.(name, List.replace_at(args, index, pin(case_node)))
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
      {name, args, rebuild} = AST.query_macro_call(node)

      options =
        args
        |> Enum.at(arg_index)
        |> List.update_at(pair_index, &Pair.put_value(&1, pin(case_node)))

      rebuild.(name, List.replace_at(args, arg_index, options))
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
