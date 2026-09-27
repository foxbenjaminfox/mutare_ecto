defmodule Mutare.Ecto.Window do
  @moduledoc false
  # The grammar inside over/2, shared by the fragment and value-expression walks.
  # Option/direction keys and shorthand columns are structure; expression operands remain
  # walkable. A pin in a window description computes structure, not a scalar parameter.

  alias Mutare.Ecto.{AST, Walk}

  @type role :: :value | :ordering | :structural

  @spec children(Macro.t(), ctx, (role(), ctx -> ctx)) :: [Walk.child(ctx)] when ctx: var
  def children({form, meta, [expression, options]}, ctx, refine) do
    expression_child = {expression, ctx, &{form, meta, [&1, options]}}

    options_children =
      case AST.unwrap_list(options) do
        nil ->
          [{options, :structural, & &1}]

        list ->
          for {{key, value}, index} <- Enum.with_index(list),
              {child, role, rebuild} <- option(AST.atom_value(key), value) do
            {child, role,
             &AST.rewrap_list(options, List.replace_at(list, index, {key, rebuild.(&1)}))}
          end
      end

    [
      expression_child
      | Enum.map(options_children, fn {child, role, rebuild} ->
          {child, refine.(role, ctx), &{form, meta, [expression, rebuild.(&1)]}}
        end)
    ]
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

  defp field({key, value}, :ordering),
    do:
      Enum.map(field(value, :ordering), fn {child, role, rebuild} ->
        {child, role, &{key, rebuild.(&1)}}
      end)

  defp field({:^, _, _} = value, _position), do: [{value, :structural, & &1}]

  defp field(value, position) do
    role =
      if AST.atom_value(value) != nil,
        do: :structural,
        else: position

    [{value, role, & &1}]
  end
end
