defmodule Mutare.Ecto.Dispatcher do
  @moduledoc false
  # Classifies a node once, then invokes only the sub-mutators that can apply to that Ecto surface.
  # The previous flat dispatch offered every node to all eight sub-mutators, which repeated macro
  # and call resolution even for ordinary literals and operators.

  alias Mutare.Ecto.{
    AST,
    BindingReorder,
    Changeset,
    Clause,
    ClauseDrop,
    Config,
    Query,
    QueryTerminal,
    RepoAggregate,
    RepoWrite,
    Surface
  }

  alias Mutare.Transform.Calls
  alias Mutare.Ecto.AST.QueryCall

  @query_key AST.query_module_key()
  @changeset_key AST.module_key(Ecto.Changeset)
  @condition_macros Surface.condition_macros()
  @clause_macros Surface.clause_macros()

  @doc "The tagged mutations applicable to one AST node."
  @spec mutations(Macro.t(), map()) :: [{atom(), Macro.t()}]
  def mutations(node, context) do
    case QueryCall.parse(node) do
      %QueryCall{name: name} = call -> query_macro_mutations(name, call, context)
      nil -> call_mutations(Calls.resolved_call(node), node, context)
    end
  end

  defp query_macro_mutations(:from, call, context), do: Query.mutations(call, context)

  defp query_macro_mutations(name, %QueryCall{node: node}, context)
       when name in @condition_macros,
       do: ClauseDrop.mutations(node, context)

  defp query_macro_mutations(name, %QueryCall{node: node} = call, context)
       when name in @clause_macros do
    Clause.mutations(call, context) ++
      BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)
  end

  defp query_macro_mutations(_name, _node, _context), do: []

  # A query macro normally takes the branch above. Keeping the query-call classification here makes
  # the dispatcher tolerant of a resolved call that has not received its macro-identity stamp yet.
  defp call_mutations({@query_key, name, _args, _rebuild}, node, context)
       when name in @condition_macros,
       do: ClauseDrop.mutations(node, context)

  defp call_mutations({@query_key, name, _args, _rebuild}, node, context)
       when name in @clause_macros,
       do: invoke([Clause, BindingReorder, ClauseDrop], node, context)

  defp call_mutations({@query_key, _name, _args, _rebuild}, node, context),
    do: QueryTerminal.mutations(node, context)

  defp call_mutations({@changeset_key, _name, _args, _rebuild}, node, context),
    do: Changeset.mutations(node, context)

  defp call_mutations({module, _name, _args, _rebuild}, node, context) do
    if module == context |> Config.from_context() |> Config.repo_key() do
      invoke([RepoAggregate, RepoWrite], node, context)
    else
      []
    end
  end

  defp call_mutations(nil, _node, _context), do: []

  defp invoke(modules, node, context),
    do: Enum.flat_map(modules, & &1.mutations(node, context))
end
