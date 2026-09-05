defmodule Mutare.Ecto.Dispatcher do
  @moduledoc false
  # Classifies a node once, then invokes only the sub-mutators that can apply to that Ecto surface
  # (NOTES "Dispatcher: classify once").

  alias Mutare.Ecto.{
    BindingReorder,
    Changeset,
    Clause,
    ClauseDrop,
    Config,
    Context,
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
  # `context` is core's callback context, unpacked here **once** into the plugin's `%Context{}`
  # (`Mutare.Ecto.Context`), which then threads to every sub-mutator — so no producer reads core's
  # map, and none guards its shape.
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
  def mutations(node, context) do
    context = Context.new(context)

    case QueryCall.parse(node) do
      %QueryCall{name: name} = call ->
        query_macro_mutations(Surface.macro_kind(name), call, context)

      nil ->
        call_mutations(Calls.resolved_call(node), node, context)
    end
  end

  defp query_macro_mutations(:from, call, context), do: Query.mutations(call, context)

  # A condition macro's operator/literal swaps are the host's (`Mutare.Ecto.Host`); its written
  # binding list reorders in place (`Mutare.Ecto.BindingReorder`).
  defp query_macro_mutations(:condition, %QueryCall{node: node} = call, context),
    # mutare:ignore[operand_swap] equivalent — two independent sub-mutator result lists, consumed as a set
    do: BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)

  defp query_macro_mutations(kind, %QueryCall{node: node} = call, context)
       when kind in [:clause, :join] do
    # mutare:ignore[operand_swap] equivalent — three independent result lists, consumed as a set
    Clause.mutations(call, context) ++
      BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)
  end

  # A free-standing `dynamic` (`Mutare.Ecto.Dynamic`) threads no query, so it never stage-drops;
  # its written binding list still reorders.
  defp query_macro_mutations(:dynamic, call, context),
    # mutare:ignore[operand_swap] equivalent — two independent sub-mutator result lists, consumed as a set
    do: Dynamic.mutations(call, context) ++ BindingReorder.mutations(call, context)

  # Only the inert remainder lands here — a `:skip`-kind macro and `nil` (an `Ecto.Query` macro
  # the plugin doesn't own); exhaustiveness is pinned by `Mutare.Ecto.Surface.macro_kinds/0`'s
  # parity test.
  defp query_macro_mutations(_kind, _node, _context), do: []

  # A registered Ecto.Query macro (`:condition`/`:clause`/`:join`/`:dynamic` in `Surface`) always
  # takes the branch above: `Mutare.Transform.Resolve` stamps macro identity for the whole tree
  # before `mutate/2` ever runs, reading the same alias/import resolution `Calls.resolved_call/1`
  # reads here — so the two classifications can never disagree for a macro this plugin registers.
  # A call that resolves to `Ecto.Query` and lands here is therefore always a function the plugin
  # doesn't route as a macro (`Ecto.Query.exclude/2`, `subquery/1`, …); `QueryTerminal` owns those.
  defp call_mutations({@query_key, _name, _args, _rebuild}, node, context),
    do: QueryTerminal.mutations(node, context)

  defp call_mutations({@changeset_key, _name, _args, _rebuild}, node, context),
    do: Changeset.mutations(node, context)

  defp call_mutations({module, _name, _args, _rebuild}, node, %Context{config: config} = context) do
    # `RepoAggregate`/`RepoWrite`'s own `RepoCall.resolve/2` re-verifies the module match and
    # yields nothing for a mismatch, so this check is a pure short-circuit, not an observable
    # decision.
    # mutare:ignore[conditional] equivalent — see above
    if module in Config.repo_keys(config) do
      invoke([RepoAggregate, RepoWrite], node, context)
    else
      []
    end
  end

  defp call_mutations(nil, _node, _context), do: []

  defp invoke(modules, node, context),
    do: Enum.flat_map(modules, & &1.mutations(node, context))
end
