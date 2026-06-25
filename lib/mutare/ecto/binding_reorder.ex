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

  alias Mutare.Ecto.{AST, Host}

  @doc "Binding-reorder mutants for `node` as `{:binding_reorder, node}` pairs, or `[]`."
  @spec mutations(Macro.t()) :: [{:binding_reorder, Macro.t()}]
  def mutations({macro, meta, args}) when is_list(args) do
    if macro in Host.clause_macros(), do: reorders(macro, meta, args), else: []
  end

  def mutations(_node), do: []

  # One mutant per pair of *positional* bindings both referenced in the body (the arguments after
  # the binding list — where `from`-less macros reference their bindings). The binding list itself
  # carries only declarations, so it is excluded from the reference test.
  defp reorders(macro, meta, args) do
    with {index, blist} <- find_binding_list(args),
         positions = positional_positions(unwrap(blist)),
         true <- length(positions) >= 2 do
      body = Enum.drop(args, index + 1)

      for {i, a} <- positions,
          {j, b} <- positions,
          i < j,
          AST.references_var?(body, a),
          AST.references_var?(body, b) do
        new_args = List.replace_at(args, index, swap(blist, i, j))
        {:binding_reorder, {macro, meta, new_args}}
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
    case unwrap(node) do
      [_ | _] = list -> Enum.all?(list, &binding_entry?/1)
      _ -> false
    end
  end

  defp binding_entry?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp binding_entry?({_key, {name, _meta, ctx}}) when is_atom(name) and is_atom(ctx), do: true
  defp binding_entry?(_node), do: false

  # The `{index_in_list, name}` of each *positional* binding, in order. Named bindings are skipped:
  # addressed by name, they never move under a positional transposition.
  defp positional_positions(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{name, _meta, ctx}, index} when is_atom(name) and is_atom(ctx) -> [{index, name}]
      {_named_or_other, _index} -> []
    end)
  end

  # Swap the two list entries at positions `i`/`j`, preserving the binding list's wrapper (Sourceror
  # block-wraps a list literal) and every entry's own metadata — entries are *reordered*, not
  # rewritten, so each renders with its original text in its new position.
  defp swap(blist, i, j) do
    list = unwrap(blist)
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    rewrap(blist, list |> List.replace_at(i, b) |> List.replace_at(j, a))
  end

  defp unwrap({:__block__, _meta, [list]}) when is_list(list), do: list
  defp unwrap(list) when is_list(list), do: list
  defp unwrap(_node), do: nil

  defp rewrap({:__block__, meta, [_list]}, new_list), do: {:__block__, meta, [new_list]}
  defp rewrap(_blist, new_list), do: new_list
end
