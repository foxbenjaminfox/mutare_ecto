defmodule Mutare.Ecto.BindingReorder do
  @moduledoc """
  Positional **binding-reorder** mutants for every standalone/pipe query macro that takes a binding
  pattern list — the `where`/`having` condition macros, `select`, `select_merge`, `order_by`,
  `group_by`, `distinct`, `join`, `preload`, `windows`, … (the condition/clause/join descriptors in
  `Mutare.Ecto.Surface`).

  A binding list maps names to the query's bindings **by position**: `[a, b]` binds `a`→1st,
  `b`→2nd. Transposing two positional entries (`[a, b]` → `[b, a]`) therefore reaches each
  referenced binding at a different source — a genuine behavioral mutant. **Named** bindings
  (`comments: c`) are addressed by name, not position, so they are left in place and never swapped.

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

  A swap is emitted only when **both** swapped bindings are referenced in the call body: it keeps the
  mutant a real reference exchange and avoids manufacturing an equivalent mutant when a declared
  binding is unused.
  """

  alias Mutare.Ecto.{AST, Surface}
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
    if Surface.binding_list_macro?(macro), do: reorders(call), else: []
  end

  def mutations(node, context) do
    case QueryCall.parse(node) do
      %QueryCall{} = call -> mutations(call, context)
      nil -> []
    end
  end

  # One mutant per pair of *positional* bindings both referenced in the body (the arguments after
  # the binding list — where `from`-less macros reference their bindings). The binding list itself
  # carries only declarations, so it is excluded from the reference test.
  defp reorders(%QueryCall{args: args} = call) do
    with {index, binding_list} <- find_binding_list(args),
         positions = BindingList.positionals(binding_list),
         # mutare:ignore[literal, conditional] equivalent — a fast-path guard; the `i < j` loop below already yields [] for fewer than two positions, so weakening or dropping this bound changes nothing
         true <- length(positions) >= 2 do
      body = Enum.drop(args, index + 1)

      for {i, a} <- positions,
          {j, b} <- positions,
          # mutare:ignore[relational] equivalent — `i < j` and `i > j` both pick each unordered pair once, and `swap(blist, list, i, j) == swap(blist, list, j, i)` with a symmetric reference test, so the produced mutant set is identical (consumed as a set)
          i < j,
          AST.references_var?(body, a),
          AST.references_var?(body, b) do
        new_args = List.replace_at(args, index, BindingList.swap(binding_list, i, j))
        {:binding_reorder, QueryCall.rebuild(call, new_args)}
      end
    else
      _ -> []
    end
  end

  # The first argument that is a binding list — a non-empty list whose every element is a positional
  # binding variable or a named binding (`key: var`) — as `{arg_index, node}`, or `nil` when the
  # macro carries none (`union(q, other)`, `limit(q, 10)`). The binding list always precedes the
  # body, so the first match is the right one (the select/ordering body is field accesses, not
  # variables, and so is never mistaken for a binding list).
  defp find_binding_list(args) do
    args
    |> Enum.with_index()
    |> Enum.find_value(fn {arg, index} ->
      case BindingList.parse(arg) do
        %BindingList{} = list -> {index, list}
        nil -> nil
      end
    end)
  end
end
