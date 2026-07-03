defmodule Mutare.Ecto.BindingReorder do
  @moduledoc """
  Positional **binding-reorder** mutants for every standalone/pipe query macro that takes a binding
  pattern list — the `where`/`having` condition macros, `select`, `select_merge`, `order_by`,
  `group_by`, `distinct`, `join`, `preload`, `windows`, …, and the free-standing `dynamic/2`
  (the condition/clause/join/dynamic descriptors in `Mutare.Ecto.Surface`).

  A binding list maps names to the query's bindings **by position**: `[a, b]` binds `a`→1st,
  `b`→2nd. Transposing two positional entries (`[a, b]` → `[b, a]`) asks whether their order
  matters. **Named** bindings (`comments: c`) are addressed by name, not position, so they are left
  in place. `_`-prefixed bindings are intentionally ignored, matching core's pattern-swap policy.

  The reorder is always delivered **in place** — by swapping the written list, never by rewriting the
  condition body. The list sits in an ordinary argument position (not inside a macro-expanded query
  fragment), so the whole macro call (itself an expression returning a query) rides Mutare's ordinary
  selector `case`; no host / `dynamic` weaving is needed. This is also what keeps the mutation honest
  about `:skip`: a `where`/`having` body may contain an author macro whose argument grammar is its
  own, and swapping the *declaration* leaves that body byte-for-byte untouched — we mutate only the
  list the author wrote. Wrong-schema field access from a swap surfaces at query-plan time (runtime),
  not compile time, so a mutant never poisons the single build.

  This covers the macros whose binding list is an **argument**. A `from`'s binding-list *source*
  (`from [a, b] in q, …`) is written at the whole-`from` level, so its reorder is delivered there
  (`Mutare.Ecto.Query`) — one whole-`from` mutant swapping the source declaration, never a per-clause
  rewrite. A scalar `from` source (`u in User`) and the join-introduced bindings are synthesized, not
  written as a list, so they never reorder.

  Every pair of eligible bindings is swapped, even when one or both are unused. Such a surviving
  mutant identifies a redundant binding declaration, matching core's pattern-swap policy.
  """

  alias Mutare.Ecto.Surface
  alias Mutare.Ecto.AST.{BindingList, QueryCall}

  @behaviour Mutare.Ecto.SubMutator

  @doc "Binding-reorder mutants for `node` as `{:binding_reorder, node}` pairs, or `[]`."
  @spec mutations(Macro.t() | QueryCall.t(), Mutare.Mutator.context()) ::
          [{:binding_reorder, Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  # Normalize the call (`Mutare.Ecto.AST.QueryCall.parse/1`) so the qualified (`Ecto.Query.select`)
  # and aliased (`Q.select`) forms reorder exactly like the bare/imported one; `rebuild` re-emits the
  # swap in the source's written form.
  def mutations(%QueryCall{name: macro} = call, _context) do
    # mutare:ignore[if_condition] equivalent — Dispatcher only ever calls BindingReorder.mutations/2 for a macro of kind :condition/:join/:clause/:dynamic (via either dispatch path), which is exactly Surface.binding_list_macro?/1's true set, so the guard always holds when reached
    if Surface.binding_list_macro?(macro), do: reorders(call), else: []
  end

  def mutations(node, context) do
    case QueryCall.parse(node) do
      %QueryCall{} = call -> mutations(call, context)
      nil -> []
    end
  end

  # One mutant per pair of reorderable positional bindings. Usage is deliberately irrelevant: an
  # unused declaration still earns a swap, as it does under core's pattern-swap mutator.
  defp reorders(%QueryCall{args: args} = call) do
    case BindingList.find(args) do
      {index, binding_list} ->
        for swapped <- BindingList.transpositions(binding_list) do
          new_args = List.replace_at(args, index, swapped)
          {:binding_reorder, QueryCall.rebuild(call, new_args)}
        end

      nil ->
        []
    end
  end
end
