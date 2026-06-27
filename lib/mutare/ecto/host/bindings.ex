defmodule Mutare.Ecto.Host.Bindings do
  @moduledoc false
  # Interprets Ecto binding declarations and renders the binding list re-declared by a hosted
  # `dynamic/2`. This is the only module that reasons about positional, named, ellipsis, and join
  # placement.

  alias Mutare.Ecto.{AST, Binding}

  @join_keys ~w(
    join inner_join left_join right_join full_join cross_join
    inner_lateral_join left_lateral_join
  )a

  @doc "The dynamic binding list established by a `from` source and its join clauses."
  @spec from(Macro.t(), [Macro.t()]) :: [Macro.t()]
  def from(source, clauses) do
    source_decls =
      case source do
        {:in, _, [lhs, _src]} -> declarations(lhs)
        _ -> []
      end

    {source_named, source_front} = Enum.split_with(source_decls, &named?/1)
    {join_positional, []} = Enum.split_with(join_bindings(clauses), &Binding.variable?/1)

    source_front ++ positioned_joins(source_front, source_named, join_positional) ++ source_named
  end

  @doc "The condition argument immediately following a binding list, or `nil`."
  @spec condition_index([Macro.t()]) :: non_neg_integer() | nil
  def condition_index(args) do
    case Enum.find_index(args, &list?/1) do
      nil -> nil
      index when index + 1 < length(args) -> index + 1
      _ -> nil
    end
  end

  @doc "Normalize a lone binding or binding list for a synthesized `dynamic/2`."
  @spec declarations(Macro.t()) :: [Macro.t()]
  def declarations(node) do
    case Binding.unwrap_list(node) do
      nil -> declaration(node)
      list -> Enum.flat_map(list, &declaration/1)
    end
  end

  @doc "The positional names eligible for a binding-reorder mutation."
  @spec positional_names([Macro.t()]) :: [atom()]
  def positional_names(bindings),
    do: for(binding <- bindings, Binding.variable?(binding), do: elem(binding, 0))

  defp list?(node) do
    case Binding.unwrap_list(node) do
      [_ | _] = list -> Enum.all?(list, &Binding.entry?/1)
      _ -> false
    end
  end

  defp declaration({name, _meta, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: [AST.clean_var(var)]

  defp declaration({key, {name, _meta, ctx} = var}) when is_atom(name) and is_atom(ctx),
    do: [{AST.keyword_key(AST.atom_value(key)), AST.clean_var(var)}]

  defp declaration({:..., _meta, _ctx}), do: [Binding.ellipsis()]
  defp declaration(_node), do: []

  defp named?({_key, _var}), do: true
  defp named?(_node), do: false

  defp join_bindings(clauses) do
    for {key, {:in, _, [lhs, _src]}} <- clauses,
        AST.atom_value(key) in @join_keys,
        declaration <- declarations(lhs),
        do: declaration
  end

  defp positioned_joins(source_front, source_named, join_positional) do
    if Enum.any?(source_front, &Binding.ellipsis?/1),
      do: join_positional,
      else: join_anchor(source_front, source_named, join_positional)
  end

  defp join_anchor(source_positional, source_named, join_positional) do
    if join_positional != [] and (source_positional == [] or source_named != []) do
      [Binding.ellipsis() | join_positional]
    else
      join_positional
    end
  end
end
