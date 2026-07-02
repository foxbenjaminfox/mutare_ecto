defmodule Mutare.Ecto.Dispatcher do
  @moduledoc false
  # Classifies a node once, then invokes only the sub-mutators that can apply to that Ecto surface.
  # The previous flat dispatch offered every node to all eight sub-mutators, which repeated macro
  # and call resolution even for ordinary literals and operators.

  alias Mutare.Ecto.{
    BindingReorder,
    Changeset,
    Clause,
    ClauseDrop,
    Config,
    Dynamic,
    Query,
    QueryTerminal,
    RepoAggregate,
    RepoWrite,
    Surface
  }

  alias Mutare.Calls
  alias Mutare.Ecto.AST.QueryCall

  # This dispatch is table-driven across *several* modules (Ecto.Query, Ecto.Changeset, the
  # configured repo), so it matches the raw `Calls.resolved_call/1` tuple against keys encoded
  # by the published `Calls.module_key/1` — never a hand-built split form.
  @query_key Calls.module_key(Ecto.Query)
  @changeset_key Calls.module_key(Ecto.Changeset)
  @doc "The tagged mutations applicable to one AST node."
  # `context` is the callback context core hands `Mutare.Ecto.mutate/2`, carrying the
  # `init/1`-parsed `%Config{}` as `:config` — a superset of `Mutare.Mutator.context()`, hence
  # `map()`, as in `Config.from_context/1`. It threads unchanged to the sub-mutators.
  @spec mutations(Macro.t(), map()) :: [Mutare.Ecto.SubMutator.tagged()]
  def mutations(node, context) do
    case QueryCall.parse(node) do
      %QueryCall{name: name} = call ->
        query_macro_mutations(Surface.macro_kind(name), call, context)

      nil ->
        call_mutations(Calls.resolved_call(node), node, context)
    end
  end

  defp query_macro_mutations(:from, call, context), do: Query.mutations(call, context)

  # A standalone/pipe condition macro (`where`/`having`/…) reorders its written binding list in place
  # (`BindingReorder`), exactly like the other binding-list macros — its operator/literal swaps are
  # the host's job, but the binding list is an ordinary argument, so it never needs the host.
  defp query_macro_mutations(:condition, %QueryCall{node: node} = call, context),
    do: BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)

  defp query_macro_mutations(kind, %QueryCall{node: node} = call, context)
       when kind in [:clause, :join] do
    Clause.mutations(call, context) ++
      BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)
  end

  # A free-standing `dynamic/1,2` builds a condition value in ordinary expression position: its
  # in-fragment SQL mutants are whole-call rewrites (`Dynamic`), and its written binding list
  # reorders in place (`BindingReorder`) — but it threads no query, so it never stage-drops.
  defp query_macro_mutations(:dynamic, call, context),
    do: Dynamic.mutations(call, context) ++ BindingReorder.mutations(call, context)

  defp query_macro_mutations(_kind, _node, _context), do: []

  # A query macro normally takes the branch above. Keeping the query-call classification here makes
  # the dispatcher tolerant of a resolved call that has not received its macro-identity stamp yet.
  defp call_mutations({@query_key, name, _args, _rebuild}, node, context) do
    case Surface.macro_kind(name) do
      :condition ->
        invoke([BindingReorder, ClauseDrop], node, context)

      kind when kind in [:clause, :join] ->
        invoke([Clause, BindingReorder, ClauseDrop], node, context)

      :dynamic ->
        invoke([Dynamic, BindingReorder], node, context)

      _other ->
        QueryTerminal.mutations(node, context)
    end
  end

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
