defmodule Mutare.Ecto.Host.Bindings do
  @moduledoc false
  # Interprets Ecto binding declarations and renders the binding list re-declared by a hosted
  # `dynamic/2`. This is the only module that reasons about positional, named, ellipsis, and join
  # placement. It also locates the condition argument a host owns — including the binding-less form
  # (`q |> where(as(:post).x > 1)`), which has no written list and so re-declares an empty one.

  alias Mutare.Ecto.{AST, Binding, Surface}
  alias Mutare.Ecto.AST.{BindingList, KeywordList}
  alias Mutare.Ecto.AST.KeywordList.Entry

  @doc "The dynamic binding list established by a `from` source and its join clauses."
  @spec from(Macro.t(), KeywordList.t()) :: [Macro.t()]
  def from(source, %KeywordList{} = clauses) do
    {source_decls, composed?} =
      case source do
        # A binding source `lhs in rhs` rebinds `rhs`'s *leading* bindings. When `rhs` composes an
        # external query — a bound variable (`x in q`), a function call (`x in build(args)`), a
        # `subquery(...)`, or any other expression — that query can carry more bindings the host can't
        # see, so an appended join must anchor to the tail (`...`) rather than sit at the next
        # contiguous slot. Only a *literal* queryable (`x in Schema`, `x in "table"`, `x in {"t", S}`)
        # has no hidden bindings — its joins follow contiguously, so it must *not* anchor.
        {:in, _, [lhs, rhs]} -> {declarations(lhs), composed_source?(rhs)}
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
    with {index, %BindingList{} = list} <- BindingList.find(args),
         binding_list = declarations(list),
         {:in, _, [lhs, _source]} <- Enum.find(Enum.drop(args, index + 1), &join_expression?/1),
         [_ | _] = join_declarations <- declarations(lhs) do
      # A standalone `join` always composes an external query, so the new binding anchors to the tail.
      append_positionals(binding_list, join_declarations, true)
    else
      _ -> []
    end
  end

  @doc "The index of the host-owned condition argument, or `nil`."
  @spec condition_index([Macro.t()]) :: non_neg_integer() | nil
  def condition_index(args) do
    case hosted_condition(args) do
      {_bindings, _condition, index} -> index
      nil -> nil
    end
  end

  @doc """
  The pieces a host needs for a hosted condition: the binding declarations re-emitted by the woven
  `dynamic/2`, the condition node, and its argument index — or `nil` when the args carry no hosted
  condition (the keyword-shorthand form).

  Two shapes resolve here:

    * a **binding-form** condition (`where(q, [u], u.x == ^v)`) — the condition sits one slot past
      the written binding list, which the woven `dynamic/2` re-declares.
    * a **binding-less** condition (`q |> where(as(:post).views > 100)`, `where(q, is_nil(c.x))`) —
      no positional list is written, so the condition is the trailing argument and the woven
      `dynamic/2` re-declares an **empty** binding list (`dynamic([], …)`). A named-binding
      (`as(:_)`), `parent_as`, or `fragment` reference resolves against the query the dynamic is
      spliced into, exactly as Ecto's own `where(q, ^dynamic)` form does. This is what lets a
      binding-less `where`/`having` still have its SQL operators/literals mutated.
  """
  @spec hosted_condition([Macro.t()]) :: {[Macro.t()], Macro.t(), non_neg_integer()} | nil
  def hosted_condition(args) do
    case locate(args) do
      {_binding_index, binding_list, condition_index} ->
        {declarations(binding_list), Enum.at(args, condition_index), condition_index}

      nil ->
        bindingless_condition(args)
    end
  end

  # The trailing argument as a host-owned condition with no binding declarations, or `nil` when it is
  # not a condition to host. The shapes that are *not* a binding-less condition: a list (a binding
  # list like `[u]`, a keyword shorthand like `[active: true]`, or an empty `[]` — none a predicate
  # body), a `^dynamic` operand (Ecto's own composition primitive, mutated where it is built —
  # `Mutare.Ecto.Dynamic` rewrites the free-standing `dynamic/1,2` call whole), and a
  # bare variable (a degenerate non-condition call). Everything else — a comparison/connective/null/
  # membership expression, possibly referencing only named bindings — is hosted; the catalog then
  # decides whether there is anything to mutate.
  @spec bindingless_condition([Macro.t()]) :: {[], Macro.t(), non_neg_integer()} | nil
  defp bindingless_condition([]), do: nil

  defp bindingless_condition(args) do
    index = length(args) - 1
    condition = Enum.at(args, index)
    if hostable_bare_condition?(condition), do: {[], condition, index}, else: nil
  end

  defp hostable_bare_condition?(node) do
    case unwrap_block(node) do
      list when is_list(list) -> false
      {:^, _meta, _args} -> false
      other -> not Binding.variable?(other)
    end
  end

  # Sourceror wraps a bare list/literal in a single-element `__block__`; unwrap it so the list and
  # pin checks above see the real shape. A genuine multi-statement block (more than one child) is not
  # a condition argument and is left as-is.
  defp unwrap_block({:__block__, _meta, [inner]}), do: inner
  defp unwrap_block(node), do: node

  # The binding-list index and the condition index one slot past it, or `nil` when the args carry no
  # binding list (or nothing follows it). `hosted_condition/1` (and, through it, `condition_index/1`)
  # derives the binding-form condition from this, so the offset lives here, not in callers; the
  # binding-less fallback lives in `bindingless_condition/1`.
  @spec locate([Macro.t()]) :: {non_neg_integer(), BindingList.t(), pos_integer()} | nil
  defp locate(args) do
    with {binding_index, binding_list} <- BindingList.find(args),
         condition_index = binding_index + 1,
         true <- condition_index < length(args) do
      {binding_index, binding_list, condition_index}
    else
      _ -> nil
    end
  end

  @doc "Normalize a lone binding or binding list for a synthesized `dynamic/2`."
  @spec declarations(Macro.t() | BindingList.t()) :: [Macro.t()]
  def declarations(%BindingList{entries: entries}), do: Enum.flat_map(entries, &declaration/1)

  def declarations(node) do
    case BindingList.parse(node) do
      %BindingList{} = list -> declarations(list)
      nil -> declaration(node)
    end
  end

  defp declaration({name, _meta, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: [Mutare.AST.clean_var(var)]

  defp declaration({key, {name, _meta, ctx} = var}) when is_atom(name) and is_atom(ctx),
    do: [{Mutare.AST.keyword_key(AST.atom_value(key)), Mutare.AST.clean_var(var)}]

  defp declaration({:..., _meta, _ctx}), do: [Binding.ellipsis()]
  defp declaration(_node), do: []

  defp named?({_key, _var}), do: true
  defp named?(_node), do: false

  # Whether a binding source's right-hand side composes an external query that may carry bindings the
  # host can't see (so an appended join must anchor to the tail). True for everything *except* a
  # literal queryable — only those contribute exactly the bindings the source pattern names.
  defp composed_source?(rhs), do: not literal_queryable?(rhs)

  # A literal queryable `from` source with no hidden bindings: a schema module (`Post`), a string/atom
  # table name (`"posts"`), or a `{source, schema}` tuple (`{"posts", Post}`). Every other shape (a
  # bound query variable, a function call, a `subquery(...)`, any expression) is an opaque composed
  # query — see `composed_source?/1`.
  defp literal_queryable?({:__aliases__, _meta, _parts}), do: true
  defp literal_queryable?({:__block__, _meta, [inner]}), do: literal_queryable?(inner)

  defp literal_queryable?({source, schema}),
    do: literal_queryable?(source) and literal_queryable?(schema)

  defp literal_queryable?(node) when is_binary(node) or is_atom(node), do: true
  defp literal_queryable?(_node), do: false

  defp join_expression?({:in, _, [_lhs, _source]}), do: true
  defp join_expression?(_node), do: false

  defp join_bindings(%KeywordList{entries: entries}) do
    for %Entry{key: key, value: {:in, _, [lhs, _src]}} <- entries,
        Surface.from_clause?(key, :join_binding),
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
