defmodule Mutare.Ecto.Host.Bindings do
  @moduledoc false
  # Interprets Ecto binding declarations and renders the binding list re-declared by a hosted
  # `dynamic/2`. This is the only module that reasons about positional, named, ellipsis, and join
  # placement. Locating the condition argument those declarations precede is
  # `Mutare.Ecto.Host.Condition`'s job, not this module's.

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
        # mutare:ignore[literal] equivalent — a non-binding source always yields source_decls: [], which forces `join_anchor/4`'s `source_positional == []` disjunct regardless of composed?, so this default is never actually consulted
        _ -> {[], false}
      end

    # A keyword `from` join LHS is always a plain positional variable (`join: c in assoc(p, :x)`) —
    # it has no `key: var` named form — so `join_bindings/1` never yields a named declaration and the
    # named half of the split is always empty. The `[]` match asserts that invariant loudly: if a
    # future/foreign shape ever violates it, fail here rather than silently drop a binding.
    {join_positional, []} = Enum.split_with(join_bindings(clauses), &Binding.variable?/1)
    append_positionals(source_decls, join_positional, composed?)
  end

  @doc """
  The `from` clause list truncated to the entries whose join bindings are visible to the clause at
  `index` — every entry up to and **including** it (`KeywordList.take/2` owns the truncation
  itself; this names the offset).

  Including the entry itself (`index + 1`, not `index`) is harmless: a *hostable* key
  (`where`/`having`/`on` — `Surface.from_clause?(_, :hosted)`) never also carries
  `:join_binding`, so the entry at `index` never itself contributes a binding; only the join
  entries *before* it (already included at `index - 1` and below) matter. Truncating one earlier
  (`index + 0`) is therefore equivalent given every current descriptor — hence the ignore below —
  while going the other way (`index + 2`, pulling in a *future* join) is a real bug (see "each
  join condition sees bindings introduced up to that join, not future joins" in host_test.exs).
  """
  @spec visible_to(KeywordList.t(), non_neg_integer()) :: KeywordList.t()
  # mutare:ignore[literal:pred] equivalent: the entry at `index` never contributes a binding
  def visible_to(%KeywordList{} = clauses, index), do: KeywordList.take(clauses, index + 1)

  @doc "The dynamic binding list visible to a standalone `join` on-condition."
  @spec join([Macro.t()]) :: [Macro.t()]
  def join(args) do
    with {index, %BindingList{} = list} <- BindingList.find(args),
         binding_list = declarations(list),
         # mutare:ignore[literal, arithmetic] equivalent — a written join binding list is always preceded by an explicit qualifier atom (Elixir can't skip a middle default arg), and neither an atom nor the binding list itself ever matches the {:in, _, [_, _]} shape Enum.find searches for, so any of these drop counts land on the same first real match
         {:in, _, [lhs, _source]} <- Enum.find(Enum.drop(args, index + 1), &join_expression?/1),
         [_ | _] = join_declarations <- declarations(lhs) do
      # A standalone `join` always composes an external query, so the new binding anchors to the tail.
      append_positionals(binding_list, join_declarations, true)
    else
      _ -> []
    end
  end

  @doc """
  Normalize a lone binding or binding list for a synthesized `dynamic/2`. `nil` — the
  binding-less form (`Mutare.Ecto.Host.Condition`) — re-declares an empty one (`dynamic([], …)`).
  """
  @spec declarations(Macro.t() | BindingList.t() | nil) :: [Macro.t()]
  # mutare:ignore[clause_drop] equivalent — without this clause `nil` falls through to `BindingList.parse/1` (not a list, so `nil`) and then `declaration/1`'s catch-all, which also yields `[]`; the explicit clause states the binding-less contract rather than relying on that fallthrough
  def declarations(nil), do: []
  def declarations(%BindingList{entries: entries}), do: Enum.flat_map(entries, &declaration/1)

  def declarations(node) do
    case BindingList.parse(node) do
      %BindingList{} = list -> declarations(list)
      nil -> declaration(node)
    end
  end

  # mutare:ignore[pattern_swap] equivalent — the body only ever uses `var` as the whole matched term, and the guard (`is_atom` of both positions) is symmetric, so which head-bound name aliases which tuple position is unobservable
  defp declaration({name, _meta, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: [Mutare.AST.clean_var(var)]

  # Only `var` as a whole is used (pattern_swap: the guard is symmetric in name/ctx, so relabeling
  # which sub-position binds to `name` vs `ctx` is unobservable), and every `{key, var}` entry this
  # clause ever receives already passed `Mutare.Ecto.Binding.entry?/1`'s identical
  # `is_atom(name) and is_atom(ctx)` check during `Mutare.Ecto.AST.BindingList.parse/1`'s
  # validation (the only way a `%BindingList{}`'s entries are built), so the guard is always true
  # by the time it's reached (logical/conditional).
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — see the comment above
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

  # mutare:ignore[pattern_swap] equivalent — `and` is commutative, so which head-bound name maps to which tuple position doesn't change the result
  defp literal_queryable?({source, schema}),
    do: literal_queryable?(source) and literal_queryable?(schema)

  defp literal_queryable?(node) when is_binary(node) or is_atom(node), do: true
  defp literal_queryable?(_node), do: false

  defp join_expression?({:in, _, [_lhs, _source]}), do: true

  # mutare:ignore[clause_drop] equivalent — in every reachable call site (Bindings.join/1's Enum.find), the join's `x in Source` expression is positionally the first element checked after the binding list, so Enum.find always matches before this catch-all would ever run; kept as a total predicate for Enum.find's contract, not for an observed false case
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

  # Anchor the appended joins to the tail with a leading `...` when their slot isn't contiguous
  # with the declared source bindings. A literal source with leading positionals and no named
  # rebind keeps the joins contiguous.
  defp join_anchor(source_positional, source_named, join_positional, composed?) do
    # The source composes an external query, so hidden bindings may sit between its declarations
    # and the appended joins.
    hidden_source_bindings? = composed?
    # An opaque/bindingless source declares no positional binding to count from.
    no_positional_to_count_from? = source_positional == []
    # A named rebind leaves the positions past it opaque.
    rebinds_by_name? = source_named != []

    needs_tail_anchor? =
      hidden_source_bindings? or no_positional_to_count_from? or rebinds_by_name?

    if join_positional != [] and needs_tail_anchor? do
      [Binding.ellipsis() | join_positional]
    else
      join_positional
    end
  end
end
