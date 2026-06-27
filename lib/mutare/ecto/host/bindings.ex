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

    # A keyword `from` join LHS is always a plain positional variable (`join: c in assoc(p, :x)`) —
    # it has no `key: var` named form — so `join_bindings/1` never yields a named declaration and the
    # named half of the split is always empty. The `[]` match asserts that invariant loudly: if a
    # future/foreign shape ever violates it, fail here rather than silently drop a binding.
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

  @doc "The index of the condition argument immediately following a binding list, or `nil`."
  @spec condition_index([Macro.t()]) :: non_neg_integer() | nil
  def condition_index(args) do
    case locate(args) do
      {_binding_index, condition_index} -> condition_index
      nil -> nil
    end
  end

  @doc """
  The pieces a host needs for a binding-form condition (`where(q, [u], u.x == ^v)`): the binding
  declarations re-emitted by the woven `dynamic/2`, the condition node, and its argument index — or
  `nil` when the args carry no hosted condition (the keyword-shorthand form).
  """
  @spec hosted_condition([Macro.t()]) :: {[Macro.t()], Macro.t(), non_neg_integer()} | nil
  def hosted_condition(args) do
    case locate(args) do
      {binding_index, condition_index} ->
        {declarations(Enum.at(args, binding_index)), Enum.at(args, condition_index),
         condition_index}

      nil ->
        nil
    end
  end

  # The binding-list index and the condition index one slot past it, or `nil` when the args carry no
  # binding list (or nothing follows it). The single place that knows the condition sits immediately
  # after the binding list — both `condition_index/1` (routing) and `hosted_condition/1` (the host)
  # derive from it, so the offset lives here, not in callers.
  defp locate(args) do
    with binding_index when not is_nil(binding_index) <- Enum.find_index(args, &list?/1),
         condition_index = binding_index + 1,
         true <- condition_index < length(args) do
      {binding_index, condition_index}
    else
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
    do: for(binding <- bindings, Binding.variable?(binding), do: Binding.variable_name(binding))

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
    {named, source_positional} = Enum.split_with(declarations, &named?/1)
    source_positional ++ positioned_joins(source_positional, named, added, composed?) ++ named
  end

  defp positioned_joins(source_positional, source_named, join_positional, composed?) do
    if Enum.any?(source_positional, &Binding.ellipsis?/1),
      do: join_positional,
      else: join_anchor(source_positional, source_named, join_positional, composed?)
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
