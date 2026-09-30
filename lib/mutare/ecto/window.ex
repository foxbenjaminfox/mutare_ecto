defmodule Mutare.Ecto.Window do
  @moduledoc false
  # The grammar inside over/2, shared by the fragment and value-expression walks.
  # Option/direction keys and shorthand columns are structure; expression operands remain
  # walkable. A pin in a window description computes structure, not a scalar parameter.
  # The window's function is Ecto's only if `Ecto.Query.WindowAPI` names it: Ecto expands any
  # other call there (`Mutare.Ecto.Walk.expanded_argument?/2`), so `over(coalesce(a, b))` is an
  # author macro, neither mutated nor entered.

  alias Mutare.Ecto.{AST, Walk}

  @type role :: :value | :ordering | :structural

  @spec children(Macro.t(), ctx, (role(), ctx -> ctx)) :: [Walk.child(ctx)] when ctx: var
  # `over/1` has no options: its function alone, under the window's own context.
  def children({form, meta, [_expression]} = node, ctx, _refine),
    do: function(node, ctx, &{form, meta, [&1]})

  def children({form, meta, [expression, options]} = node, ctx, refine) do
    expression_children = function(node, ctx, &{form, meta, [&1, options]})

    options_children =
      case AST.unwrap_list(options) do
        nil ->
          [{options, :structural, & &1}]

        list ->
          for {entry, index} <- Enum.with_index(list),
              {key, value} <- [AST.unwrap_pair(entry)],
              {child, role, rebuild} <- option(AST.atom_value(key), value) do
            {child, role,
             &AST.rewrap_list(
               options,
               List.replace_at(list, index, AST.rewrap_pair(entry, {key, rebuild.(&1)}))
             )}
          end
      end

    expression_children ++
      Enum.map(options_children, fn {child, role, rebuild} ->
        {child, refine.(role, ctx), &{form, meta, [expression, rebuild.(&1)]}}
      end)
  end

  defp function({_form, _meta, [expression | _options]} = node, ctx, rebuild) do
    if Walk.expanded_argument?(node, 0),
      do: [],
      else: [{expression, ctx, rebuild}]
  end

  defp option(:order_by, value), do: fields(value, :ordering)
  defp option(:partition_by, value), do: fields(value, :value)
  defp option(:frame, value), do: [{value, :value, & &1}]

  defp fields(value, position) do
    case AST.unwrap_list(value) do
      nil ->
        field(value, position)

      list ->
        for {entry, index} <- Enum.with_index(list),
            {child, role, rebuild} <- field(entry, position),
            do: {child, role, &AST.rewrap_list(value, List.replace_at(list, index, rebuild.(&1)))}
    end
  end

  # A sort entry is a bare term or a `direction => term` pair, written as a keyword element or
  # an explicit tuple.
  defp field(entry, :ordering) do
    case AST.unwrap_pair(entry) do
      {key, value} ->
        direction_children(key, value, entry) ++
          Enum.map(field_term(value, :ordering), fn {child, role, rebuild} ->
            {child, role, &AST.rewrap_pair(entry, {key, rebuild.(&1)})}
          end)

      nil ->
        field_term(entry, :ordering)
    end
  end

  defp field(value, position), do: field_term(value, position)

  # A pinned direction (`{^direction, p.id}`, which Ecto takes) computes structure.
  defp direction_children({:^, _meta, [_interior]} = key, value, entry),
    do: [{key, :structural, &AST.rewrap_pair(entry, {&1, value})}]

  defp direction_children(_key, _value, _entry), do: []

  defp field_term({:^, _, _} = value, _position), do: [{value, :structural, & &1}]

  defp field_term(value, position) do
    role =
      if AST.atom_value(value) != nil,
        do: :structural,
        else: position

    [{value, role, & &1}]
  end
end
