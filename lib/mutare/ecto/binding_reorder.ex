defmodule Mutare.Ecto.BindingReorder do
  @moduledoc """
  Positional **binding-reorder** mutants for the standalone/pipe query macros that take a binding
  pattern list — `select`, `select_merge`, `order_by`, `group_by`, `distinct`, `join`, `preload`,
  `windows`, … (the `Mutare.Ecto.Host.clause_macros/0` set).

  A binding list maps names to the query's bindings **by position**: `[a, b]` binds `a`→1st,
  `b`→2nd. Transposing two positional entries (`[a, b]` → `[b, a]`) therefore reaches each
  referenced binding at a different source — a genuine behavioral mutant, the same swap
  `Mutare.Ecto.Fragment` makes for a `where`/`having` condition (which the host owns). **Named**
  bindings (`comments: c`) are addressed by name, not position, so they are left in place and never
  swapped.

  Unlike the in-fragment families, this mutation is delivered **in place**: the binding list sits in
  an argument position — not inside a macro-expanded query fragment — so the whole macro call (itself
  an expression returning a query) rides Mutare's ordinary selector `case`. No host / `dynamic`
  weaving is needed; wrong-schema field access from a swap surfaces at query-plan time (runtime), not
  compile time, so a mutant never poisons the single build.

  A swap is emitted only when **both** swapped bindings are referenced in the call body, mirroring
  the host's rule (`Mutare.Ecto.Fragment.binding_reorders/2`): it keeps the mutant a real reference
  exchange and avoids manufacturing an equivalent mutant when a declared binding is unused.
  """

  alias Mutare.Ecto.{AST, Binding, Host}

  @behaviour Mutare.Ecto.SubMutator

  @doc "Binding-reorder mutants for `node` as `{:binding_reorder, node}` pairs, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [{:binding_reorder, Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  # Normalize the call (`Mutare.Ecto.AST.query_macro_call/1`) so the qualified (`Ecto.Query.select`)
  # and aliased (`Q.select`) forms reorder exactly like the bare/imported one; `rebuild` re-emits the
  # swap in the source's written form.
  def mutations(node, _context) do
    case AST.query_macro_call(node) do
      {macro, args, rebuild} ->
        if macro in Host.clause_macros(), do: reorders(macro, args, rebuild), else: []

      nil ->
        []
    end
  end

  # One mutant per pair of *positional* bindings both referenced in the body (the arguments after
  # the binding list — where `from`-less macros reference their bindings). The binding list itself
  # carries only declarations, so it is excluded from the reference test.
  defp reorders(macro, args, rebuild) do
    with {index, blist} <- find_binding_list(args),
         positions = positional_positions(Binding.unwrap_list(blist)),
         # mutare:ignore[literal, conditional] equivalent — a fast-path guard; the `i < j` loop below already yields [] for fewer than two positions, so weakening or dropping this bound changes nothing
         true <- length(positions) >= 2 do
      body = Enum.drop(args, index + 1)

      for {i, a} <- positions,
          {j, b} <- positions,
          # mutare:ignore[relational] equivalent — `i < j` and `i > j` both pick each unordered pair once, and `swap(blist, i, j) == swap(blist, j, i)` with a symmetric reference test, so the produced mutant set is identical (consumed as a set)
          i < j,
          AST.references_var?(body, a),
          AST.references_var?(body, b) do
        new_args = List.replace_at(args, index, swap(blist, i, j))
        {:binding_reorder, rebuild.(macro, new_args)}
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
    |> Enum.find_value(fn {arg, index} -> if binding_list?(arg), do: {index, arg} end)
  end

  defp binding_list?(node) do
    case Binding.unwrap_list(node) do
      # mutare:ignore[return_value, collection] equivalent — the binding list is always the first list-shaped argument and is all binding entries; a partial/non-entry list at that position never occurs, so all?/any? and the boolean return are indistinguishable on reachable input
      [_ | _] = list -> Enum.all?(list, &binding_entry?/1)
      _ -> false
    end
  end

  # A binding-list element: a named binding (`key: var`, a 2-tuple), or — for any other node — a
  # positional variable or the `...` anchor. The named clause precedes the catch-all so a 2-tuple is
  # tested by its bound var, not mistaken for a (non-variable) leaf.
  #
  # Both clauses only gate *list recognition*; `positional_positions/1` re-filters every entry with
  # `Binding.variable?/1`, and `find_binding_list/1` already takes the first list-shaped argument
  # (always the real binding list), so over-accepting an entry changes neither selection nor the swap.
  # mutare:ignore[return_value] equivalent — a named pair's truthiness only flags the list as a binding list; a non-variable value yields no position downstream, so any truthy return is indistinguishable from `variable?(var)`
  defp binding_entry?({_key, var}), do: Binding.variable?(var)

  # mutare:ignore[conditional] equivalent — forcing this to `true` only widens which lists are recognized; the first list-shaped arg is still the binding list and positional_positions re-filters to variables, so no swap changes
  defp binding_entry?(node), do: Binding.variable?(node) or Binding.ellipsis?(node)

  # The `{index_in_list, name}` of each *positional* binding, in order. Named bindings and the `...`
  # anchor are skipped (`Binding.variable?/1` rejects both): they never move under a positional swap.
  defp positional_positions(list) do
    for {entry, index} <- Enum.with_index(list),
        Binding.variable?(entry),
        do: {index, elem(entry, 0)}
  end

  # Swap the two list entries at positions `i`/`j`, preserving the binding list's wrapper (Sourceror
  # block-wraps a list literal) and every entry's own metadata — entries are *reordered*, not
  # rewritten, so each renders with its original text in its new position.
  defp swap(blist, i, j) do
    list = Binding.unwrap_list(blist)
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    rewrap(blist, list |> List.replace_at(i, b) |> List.replace_at(j, a))
  end

  # mutare:ignore[clause_drop, atom] equivalent — the block wrapper carries only source-formatting meta; the reordered list renders identically whether re-wrapped or returned bare, so matching or dropping this clause is unobservable
  defp rewrap({:__block__, meta, [_list]}, new_list), do: {:__block__, meta, [new_list]}

  # mutare:ignore[clause_drop] equivalent — a parsed binding list reaches swap/2 block-wrapped, so this bare-list fallback is unreachable from valid Ecto
  defp rewrap(_blist, new_list), do: new_list
end
