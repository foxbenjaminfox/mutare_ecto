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
    {source_decls, composed?} =
      case source do
        # `x in <var>` composes an *external* query: the source rebinds its leading bindings, but the
        # query can carry more the host can't see, so an appended join must anchor to the tail (`...`)
        # rather than sit at the next contiguous slot. `x in Schema` (a literal source) has no hidden
        # bindings — the joins follow contiguously, so it must *not* anchor.
        {:in, _, [lhs, rhs]} -> {declarations(lhs), Binding.variable?(rhs)}
        _ -> {[], false}
      end

    {join_positional, []} = Enum.split_with(join_bindings(clauses), &Binding.variable?/1)
    append_positionals(source_decls, join_positional, composed?)
  end

  @doc "The dynamic binding list visible to a standalone `join` on-condition."
  @spec join([Macro.t()]) :: [Macro.t()]
  def join(args) do
    with index when not is_nil(index) <- Enum.find_index(args, &list?/1),
         binding_list = declarations(Enum.at(args, index)),
         {:in, _, [lhs, _source]} <- Enum.find(Enum.drop(args, index + 1), &join_expression?/1),
         [_ | _] = join_declarations <- declarations(lhs) do
      # A standalone `join` always composes an external query, so the new binding anchors to the tail.
      append_positionals(binding_list, join_declarations, true)
    else
      _ -> []
    end
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

  @doc "Whether a keyword pair is a join's `on:` option — the hosted condition of a `join`."
  @spec on_pair?(Macro.t()) :: boolean()
  def on_pair?({key, _value}), do: AST.atom_value(key) == :on
  def on_pair?(_node), do: false

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

  defp join_expression?({:in, _, [_lhs, _source]}), do: true
  defp join_expression?(_node), do: false

  defp join_bindings(clauses) do
    for {key, {:in, _, [lhs, _src]}} <- clauses,
        AST.atom_value(key) in @join_keys,
        declaration <- declarations(lhs),
        do: declaration
  end

  defp append_positionals(declarations, added, composed?) do
    {named, front} = Enum.split_with(declarations, &named?/1)
    front ++ positioned_joins(front, named, added, composed?) ++ named
  end

  defp positioned_joins(source_front, source_named, join_positional, composed?) do
    if Enum.any?(source_front, &Binding.ellipsis?/1),
      do: join_positional,
      else: join_anchor(source_front, source_named, join_positional, composed?)
  end

  # Anchor the appended joins to the tail with a leading `...` when their slot isn't contiguous with
  # the declared source bindings: the source composes an external query (`composed?` — hidden
  # bindings may sit between), declares no positional binding to count from (`source_positional == []`
  # — an opaque/bindingless source), or rebinds by name (`source_named != []` — names leave the
  # positions past them opaque). A literal source with leading positionals and no anchor keeps the
  # joins contiguous.
  defp join_anchor(source_positional, source_named, join_positional, composed?) do
    if join_positional != [] and
         (composed? or source_positional == [] or source_named != []) do
      [Binding.ellipsis() | join_positional]
    else
      join_positional
    end
  end
end
