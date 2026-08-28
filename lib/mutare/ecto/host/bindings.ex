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
        # A piped `from`'s source is the hidden `|>` left side (`Mutare.Ecto.AST.FromCall`): it
        # declares no binding, and — unseen — may be anything, so it is read as composed.
        nil -> {[], true}
        # A bare queryable source (`from(Post, …)`, `from("t", as: :t, …)`, `from(q, …)`) declares
        # no binding; its composed-ness is read off the queryable itself, exactly as for an `in`
        # rhs. (With no positional to count from, `join_anchor/4` anchors an appended join either
        # way — the value is honest, not load-bearing, for this and the hidden source alike.)
        _ -> {[], composed_source?(source)}
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
    # The join's `x in Source` expression sits one slot past the written binding list: Ecto's
    # `join(query, qual, binding \\ [], expr, opts \\ [])` can't skip the middle default, so a
    # join written with options (the `on:` the host weaves) always writes its list too — and may
    # legally write it **empty** (`join(q, :inner, [], p in Post, on: p.views > 1)`: the
    # condition references only the joined binding). The list is located through `written/1`,
    # not `BindingList.find/1`, precisely so that `[]` counts as the declaration it is; located
    # through `find/1` it fell through here, and the join kept only its stage drop.
    with {index, written} <- find_written(args),
         {:in, _, [lhs, _source]} <- Enum.at(args, index + 1),
         [_ | _] = join_declarations <- declarations(lhs) do
      # A standalone `join` always composes an external query, so the new binding anchors to the tail.
      append_positionals(written, join_declarations, true)
    else
      _ -> []
    end
  end

  # The first written binding list in `args` with its index, or `nil` — `written/1` decides what
  # counts, so the empty list is found exactly as a populated one is.
  defp find_written(args) do
    args
    |> Enum.with_index()
    |> Enum.find_value(fn {node, index} ->
      case written(node) do
        nil -> nil
        declarations -> {index, declarations}
      end
    end)
  end

  @doc """
  Normalize a lone binding or binding list for a synthesized `dynamic/2`: the `lhs` of a
  `lhs in rhs` source or join — a binding list, the empty `[]`, or a single positional variable.
  `nil` — the binding-less form (`Mutare.Ecto.Host.Condition`) — re-declares an empty one
  (`dynamic([], …)`).
  """
  @spec declarations(Macro.t() | BindingList.t() | nil) :: [Macro.t()]
  # The binding-less form's written list. Load-bearing, not defensive: `nil` is the one shape the
  # general clause below can't read — no list, so `written/1` declines it and the lone-variable
  # branch would try to re-declare `nil` itself.
  def declarations(nil), do: []

  def declarations(%BindingList{entries: entries}), do: Enum.map(entries, &declaration/1)

  def declarations(node) do
    case written(node) do
      # Not a list at all: a lone positional variable (`x in q`).
      nil -> [Mutare.AST.clean_var(node)]
      declarations -> declarations
    end
  end

  # The declarations of a *written* binding list, or `nil` for any other node. A written list is a
  # `BindingList` — or the empty `[]`, which `BindingList.parse/1` declines (it is the *reorderable*
  # list, and `[]` has nothing to reorder) but which is a legal declaration of exactly nothing: a
  # lone `[] in q` source, or a standalone join's prior bindings (`join/1`).
  defp written(node) do
    case BindingList.parse(node) do
      %BindingList{} = list -> declarations(list)
      nil -> if AST.unwrap_list(node) == [], do: [], else: nil
    end
  end

  # One parsed `%BindingList{}` entry, re-declared. `Mutare.Ecto.AST.BindingList.parse/1` (the
  # only way entries are built) already validated each as a named pair, a positional variable, or
  # the `...` anchor (`Mutare.Ecto.Binding.entry?/1`), so no shape is re-checked here.
  defp declaration({key, var}),
    do: {Mutare.AST.keyword_key(AST.atom_value(key)), Mutare.AST.clean_var(var)}

  defp declaration({:..., _meta, _ctx}), do: Binding.ellipsis()
  defp declaration(var), do: Mutare.AST.clean_var(var)

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

  # `and` is commutative, so which head-bound name maps to which tuple position is unobservable.
  # mutare:ignore[pattern_swap] equivalent — see above
  defp literal_queryable?({source, schema}),
    do: literal_queryable?(source) and literal_queryable?(schema)

  defp literal_queryable?(node) when is_binary(node) or is_atom(node), do: true
  defp literal_queryable?(_node), do: false

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
