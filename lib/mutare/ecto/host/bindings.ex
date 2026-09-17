defmodule Mutare.Ecto.Host.Bindings do
  @moduledoc false
  # Interprets Ecto binding declarations and renders the binding list re-declared by a hosted
  # `dynamic/2`. This is the only module that reasons about positional, named, ellipsis, and join
  # placement. Locating the condition argument those declarations precede is
  # `Mutare.Ecto.Host.Condition`'s job, not this module's.
  #
  # The list is positional, and every branch of a hosted selector is resolved through it — the
  # *original* condition's branch included. So a list that misplaces a binding does not just emit
  # a bad mutant: it rewrites the baseline, and where two tables share a column name the result is
  # valid SQL over the wrong table. Hence the rule `join_slot/1` is the home of: a synthesized list
  # accounts for **every** position its joins establish, named by the author or not — each join
  # clause of a `from` (`join_slots/1`), and the one join a standalone `join/4,5` adds (`join/1`).
  #
  # Every reader here answers `{:ok, declarations} | :error`, and the two are never blurred:
  # `{:ok, []}` says the query position declares **nothing** (an omitted or empty list, a bare
  # queryable source), so a woven `dynamic([], …)` is faithful; `:error` says a declaration was
  # written that this module **cannot interpret** (`Mutare.Ecto.Binding`'s grammar), so *any*
  # re-declaration would be a guess and the condition is never woven — it is rebuilt whole-call
  # instead (`Mutare.Ecto.StaticCondition.delivery/4`). The work is done on parsed entries
  # (`t:Mutare.Ecto.Binding.entry/0`) and rendered to AST once, at the end — placement never
  # re-reads a node's shape to learn what kind of entry it is.

  alias Mutare.Ecto.{Binding, Surface}
  alias Mutare.Ecto.AST.{BindingList, KeywordList}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.Condition

  @typedoc "The binding list a woven `dynamic/2` re-declares, or `:error` — see the module comment."
  @type result :: {:ok, [Macro.t()]} | :error

  @doc "The dynamic binding list established by a `from` source and its join clauses."
  @spec from(Macro.t() | nil, KeywordList.t()) :: result()
  def from(source, %KeywordList{} = clauses) do
    with {:ok, declared, composed?} <- source_entries(source),
         {:ok, joined} <- join_slots(clauses) do
      {:ok, declared |> append_joins(joined, composed?) |> render()}
    end
  end

  # The entries a `from` source declares, and whether the source is **composed** — may carry
  # bindings the host can't see.
  #
  # A binding source `lhs in rhs` rebinds `rhs`'s *leading* bindings. When `rhs` composes an
  # external query — a bound variable (`x in q`), a function call (`x in build(args)`), a
  # `subquery(...)`, or any other expression — that query can carry more bindings the host can't
  # see, so an appended join must anchor to the tail (`...`) rather than sit at the next contiguous
  # slot. Only a *literal* queryable (`x in Schema`, `x in "table"`, `x in {"t", S}`) has no hidden
  # bindings — its joins follow contiguously, so it must *not* anchor.
  defp source_entries({:in, _meta, [lhs, rhs]}) do
    with {:ok, declared} <- pattern_entries(lhs), do: {:ok, declared, composed_source?(rhs)}
  end

  # A piped `from`'s source is the hidden `|>` left side (`Mutare.Ecto.AST.FromCall`), which no
  # callback is shown. It is read as a **queryable value** — declaring nothing, and composed,
  # since unseen it may be any query. That is an assumption, not an observation, and it is
  # exactly the one core's pipe hoisting already makes about every pipe's left side (it binds it
  # to a variable): a binding *pattern* there (`(p in Post) |> from(…)`) breaks core's delivery
  # before this reading of it matters (NOTES "A binding pattern on a pipe's left
  # (`(p in Post) |> from(…)`) is unsupported").
  defp source_entries(nil), do: {:ok, [], true}

  # A bare queryable source (`from(Post, …)`, `from("t", as: :t, …)`, `from(q, …)`) declares
  # no binding; its composed-ness is read off the queryable itself, exactly as for an `in`
  # rhs. (With no positional to count from, `join_anchor/4` anchors an appended join either
  # way — the value is honest, not load-bearing, for this and the hidden source alike.)
  defp source_entries(source), do: {:ok, [], composed_source?(source)}

  # The `lhs` of a `lhs in rhs` source: Ecto `List.wrap/1`s it, so it is a declaration list or
  # one lone entry (`p in Post`).
  defp pattern_entries(lhs) do
    case BindingList.parse(lhs) do
      {:ok, %BindingList{entries: entries}} -> {:ok, entries}
      :error -> with {:ok, entry} <- Binding.parse(lhs), do: {:ok, [entry]}
    end
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

  @doc """
  The dynamic binding list visible to a standalone `join`'s on-condition: the written
  declaration plus the slot of the join itself, named or not (`join_slot/1`).

  Read **by position from the end** — `join(query, qual, binding \\\\ [], expr, opts \\\\ [])`
  can't skip the middle default, so a join written with options (the `on:` the host weaves)
  always writes its declaration too, third from last in the direct and piped forms alike. It may
  legally be **empty** (`join(q, :inner, [], p in Post, on: p.views > 1)`: the condition
  references only the joined binding), which is the declaration it looks like, not a missing
  one. The host calls this only for a call whose last argument is that options list.
  """
  @spec join([Macro.t()]) :: result()
  def join(args) do
    with [written, join, _options] <- Enum.take(args, -3),
         {:ok, %BindingList{entries: declared}} <- BindingList.parse(written),
         {:ok, slot} <- join_slot(join) do
      # The `on:` is resolved with the new join in place, so the join's slot is declared whether
      # or not it is named — after an author-written `[..., x]` the `_` is what keeps `x` on the
      # binding it named: `[..., x, _]`, where `[..., x]` would now read the new join. A standalone
      # `join` always composes an external query, so the slot anchors to the tail.
      {:ok, declared |> append_joins([slot], true) |> render()}
    else
      _ -> :error
    end
  end

  @doc """
  The binding list a woven `dynamic/2` re-declares for a located condition's declaration
  (`t:Mutare.Ecto.Host.Condition.declaration/0`): the written entries, an empty list for an
  omitted one, and `:error` — never an empty list — for one the plugin cannot interpret.
  """
  @spec declarations(Condition.declaration()) :: result()
  def declarations(%BindingList{entries: entries}), do: {:ok, render(entries)}
  def declarations(:omitted), do: {:ok, []}
  def declarations(:uninterpretable), do: :error

  defp render(entries), do: Enum.map(entries, &declaration/1)

  # One entry, re-declared with fresh meta (the written nodes stay where they were written).
  defp declaration(:ellipsis), do: Binding.ellipsis()
  defp declaration({:positional, var}), do: Mutare.AST.clean_var(var)

  defp declaration({:indexed, var, index}),
    do: {Mutare.AST.clean_var(var), Mutare.AST.literal(index)}

  defp declaration({:named, name, var}),
    do: {Mutare.AST.keyword_key(name), Mutare.AST.clean_var(var)}

  defp declaration({:interpolated, name_expr, var}),
    do: {{:^, [], [clean_name(name_expr)]}, Mutare.AST.clean_var(var)}

  # `Mutare.Ecto.Binding` admits exactly these two name expressions.
  defp clean_name({:@, _meta, [attribute]}), do: {:@, [], [Mutare.AST.clean_var(attribute)]}
  defp clean_name(var), do: Mutare.AST.clean_var(var)

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

  # One slot per join clause, in written order, all or nothing: **every join occupies exactly one
  # positional slot**, whether or not the author names it. Ecto's join builder binds a join written
  # without `x in` — `cross_join: "audit"`, `join: subquery(q)`, `left_join: assoc(p, :x)`, a
  # `fragment`, a `^source` — anonymously, and still advances the binding count
  # (`Ecto.Query.Builder.Join.escape/3` answers `:_`). So an unnamed join re-declares as the `_`
  # placeholder, never as nothing: a dropped slot shifts every join counted *across* it onto its
  # neighbour's table — the joins after it under a literal source (counted from the front), the
  # joins before it under a `...`-anchored one (counted from the tail). That second direction is
  # why no ellipsis can stand in for a missing slot, and why a trailing `_` is kept rather than
  # trimmed: redundant after a literal source, it is what places `c` in `[p, ..., c, _]`.
  defp join_slots(%KeywordList{entries: entries}) do
    slots =
      for %Entry{key: key, value: value} <- entries,
          Surface.from_clause?(key, :join_binding),
          do: join_slot(value)

    if Enum.all?(slots, &match?({:ok, _entry}, &1)),
      do: {:ok, for({:ok, entry} <- slots, do: entry)},
      else: :error
  end

  # The slot of one join expression — a `from` join clause's value, or a standalone `join/4,5`'s
  # `expr` argument: Ecto reads both through the same `Join.escape/3`. A join names its slot only
  # as `var in source`, with one plain variable on the left — no list, no `key: var` form (Ecto
  # reads anything else as a malformed join) — so any other left side is `:error`, not a guess.
  defp join_slot({:in, _meta, [lhs, _source]}) do
    case Binding.parse(lhs) do
      {:ok, {:positional, _var} = entry} -> {:ok, entry}
      _other -> :error
    end
  end

  defp join_slot(_unnamed), do: {:ok, {:positional, Binding.placeholder()}}

  # Ecto wants the named entries at the tail, so the joins (positional) go in before them.
  defp append_joins(declared, joined, composed?) do
    {positional, named} = Enum.split_with(declared, &Binding.positional?/1)
    positional ++ positioned_joins(positional, named, joined, composed?) ++ named
  end

  defp positioned_joins(positional, named, joined, composed?) do
    if :ellipsis in positional,
      do: joined,
      else: join_anchor(positional, named, joined, composed?)
  end

  # Anchor the appended joins to the tail with a leading `...` when their list position would not
  # be their binding index. It is only for a literal source declared by exactly one positional
  # entry and no named rebind; those joins stay contiguous.
  defp join_anchor(positional, named, joined, composed?) do
    # The source composes an external query, so hidden bindings may sit between its declarations
    # and the appended joins.
    hidden_source_bindings? = composed?
    # A literal source is exactly one binding, so its joins are bindings 1, 2, … — which is
    # where the list puts them only when one positional entry precedes them. None (an
    # opaque/bindingless source) leaves nothing to count from; two (`[p, q]`, or
    # `[{p, 0}, {q, 0}]`) are two entries over that one binding.
    source_not_one_entry? = length(positional) != 1
    # A named rebind leaves the positions past it opaque.
    rebinds_by_name? = named != []

    needs_tail_anchor? = hidden_source_bindings? or source_not_one_entry? or rebinds_by_name?

    if joined != [] and needs_tail_anchor? do
      [:ellipsis | joined]
    else
      joined
    end
  end
end
