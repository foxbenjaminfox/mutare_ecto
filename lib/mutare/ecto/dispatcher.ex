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
  @spec mutations(Macro.t(), map()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
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
    # mutare:ignore[operand_swap] equivalent — two independent sub-mutator result lists, consumed as a set
    do: BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)

  defp query_macro_mutations(kind, %QueryCall{node: node} = call, context)
       when kind in [:clause, :join] do
    # mutare:ignore[operand_swap] equivalent — three independent sub-mutator result lists, consumed as a set regardless of concatenation grouping/order
    Clause.mutations(call, context) ++
      BindingReorder.mutations(call, context) ++ ClauseDrop.mutations(node, context)
  end

  # A free-standing `dynamic/1,2` builds a condition value in ordinary expression position: its
  # in-fragment SQL mutants are whole-call rewrites (`Dynamic`), and its written binding list
  # reorders in place (`BindingReorder`) — but it threads no query, so it never stage-drops.
  defp query_macro_mutations(:dynamic, call, context),
    # mutare:ignore[operand_swap] equivalent — two independent sub-mutator result lists, consumed as a set
    do: Dynamic.mutations(call, context) ++ BindingReorder.mutations(call, context)

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

  defp call_mutations({module, _name, _args, _rebuild}, node, context) do
    # mutare:ignore[conditional] equivalent — RepoAggregate/RepoWrite's own RepoCall.resolve/2 independently re-verifies the module match and yields no mutation for a mismatch either way, so skipping the invoke/2 call here is a pure optimization, not an observable difference
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
