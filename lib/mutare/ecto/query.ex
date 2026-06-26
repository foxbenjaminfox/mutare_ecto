defmodule Mutare.Ecto.Query do
  @moduledoc """
  Whole-`from` query mutations — the ones expressible **without** Mutare's foreign-semantics
  DSL host (Bucket 1 of `DESIGN.md`). Each returns a whole mutated `from(...)` node, which
  Mutare's ordinary in-place selector wraps; the localized in-fragment mutations (operator
  swaps inside a `where`, via `^`/`dynamic`) arrive with the host extensions.

    * **Clause drop** — remove one `where`/`having`/`or_where`/`or_having` clause from the
      query. "Is this filter tested?" Reuses the surviving clauses, so it always compiles, and
      works for both the binding form (`from p in Post, where: p.active`) and the bindingless
      form (`from Post, where: [active: true]`) since it operates on the clause list, not the
      clause value.
    * **Order flip** — flip an `order_by` direction (`:asc`↔`:desc`, and the `*_nulls_*`
      variants). "Does any test pin the sort direction?"
    * **Bound** — drop a `limit`/`offset` clause, and bump its integer value by `±1` (the
      off-by-one boundary). "Does any test pin the page size / window edge?" Non-negative only
      (a negative `limit`/`offset` is invalid SQL), and a `^pinned` or expression bound is left
      to its own value mutation — only a literal integer is bumped here.
    * **JoinType** — swap a join's kind by rewriting its clause *key*: `join`/`inner_join`
      ↔ `left_join`. "Does any test exercise rows the join's cardinality changes?" An inner
      join drops rows a left join keeps, so the swap is a strong, killable mutation. The
      **portable** pair (every adapter supports `INNER`/`LEFT`) is always offered; the
      `LEFT`↔`RIGHT` pair is **dialect-gated** (`:postgres`/`:mysql` — SQLite lacks `RIGHT`),
      and the `*`→`FULL` swap is gated to `:postgres`/`:sqlite` (MySQL has no `FULL JOIN`).
    * **Aggregate (in `select`/`order_by`)** — swap an aggregate inside a `select`/`select_merge`
      or `order_by` clause value (`sum`↔`avg`, `min`↔`max`), via the shared `Mutare.Ecto.Aggregate`
      walker. "Does any test pin which aggregate the column is reduced/sorted by?" (An aggregate
      inside a `having` is delivered through the host instead — see `Mutare.Ecto.Host`.)

  Each mutation is returned as `{family, node}` so the caller can filter by `families:`; `opts`
  carries `dialects:` for the join gate. A `from` node is `{:from, meta, [source, clauses]}`
  where `clauses` is a keyword list (in Sourceror form, each key wrapped as
  `{:__block__, [format: :keyword], [atom]}`). `from/1` (`from(Post)`, no clauses) yields nothing.
  """

  alias Mutare.Ecto.{Aggregate, AST, Config, Ordering}

  @type family :: atom()

  @droppable ~w(where having or_where or_having)a
  @bound_keys ~w(limit offset)a
  @aggregate_keys ~w(select select_merge order_by)a

  # JoinType: each join-clause key's kind swaps. `join` is the keyword-form default inner join.
  # The portable pair (`INNER`↔`LEFT`) is always offered; the non-portable pairs are added only
  # under a dialect that supports them:
  #
  #   * `LEFT`↔`RIGHT` — `@right_join_dialects` (`:postgres`/`:mysql`); SQLite lacks `RIGHT JOIN`.
  #   * `*`→`FULL` (and `FULL`→`LEFT`) — `@full_join_dialects` (`:postgres`/`:sqlite` ≥ 3.39);
  #     MySQL has no `FULL JOIN` at any version. This is an *introducing* swap (the source's
  #     `inner`/`left` becomes a `FULL` not written by the user), so it must be dialect-gated —
  #     unlike a swap that only permutes a form already in the source.
  @portable_join_flips %{join: [:left_join], inner_join: [:left_join], left_join: [:inner_join]}
  @right_join_flips %{left_join: [:right_join], right_join: [:left_join]}
  @right_join_dialects [:postgres, :mysql]
  @full_join_flips %{
    join: [:full_join],
    inner_join: [:full_join],
    left_join: [:full_join],
    right_join: [:full_join],
    full_join: [:left_join]
  }
  @full_join_dialects [:postgres, :sqlite]

  @doc "Whole-`from` mutations for a `from(...)` node as `{family, node}` pairs, or `[]`."
  @spec mutations(Macro.t(), keyword()) :: [{family(), Macro.t()}]
  def mutations(node, opts \\ [])

  # mutare:ignore[guard_drop] equivalent — a from's clause argument is always a keyword list; a non-list is malformed AST (a `from(S)` with no clauses is a one-element arg list, caught by the fallthrough clause)
  def mutations({:from, meta, [source, clauses]}, opts) when is_list(clauses) do
    Enum.concat([
      tag(:filter_drop, drops(meta, source, clauses, @droppable)),
      tag(:bound, drops(meta, source, clauses, @bound_keys)),
      order_flips(meta, source, clauses),
      tag(:bound, bound_bumps(meta, source, clauses)),
      tag(:join_type, join_swaps(meta, source, clauses, opts)),
      tag(:aggregate, aggregate_swaps(meta, source, clauses))
    ])
  end

  def mutations(_node, _opts), do: []

  defp tag(family, nodes), do: Enum.map(nodes, &{family, &1})

  # Remove each clause whose key is in `keys`, keeping the others — so the query still
  # compiles (it reuses the surviving clauses). Used for both the filter drops (where/having)
  # and the bound drops (limit/offset).
  defp drops(meta, source, clauses, keys) do
    for {pair, index} <- Enum.with_index(clauses), clause_key(pair) in keys do
      {:from, meta, [source, List.delete_at(clauses, index)]}
    end
  end

  # Bump each `limit`/`offset` whose value is a literal integer by `±1` (non-negative only).
  # A `^pinned`/expression bound has no literal here, so it yields nothing — its value is
  # mutated where it is bound, in ordinary Elixir.
  defp bound_bumps(meta, source, clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      with true <- clause_key(pair) in @bound_keys,
           n when is_integer(n) <- AST.int_value(clause_value(pair)) do
        for bumped <- AST.bumps(n) do
          {:from, meta,
           [source, List.replace_at(clauses, index, put_value(pair, AST.int_literal(bumped)))]}
        end
      else
        _ -> []
      end
    end)
  end

  # Swap each join clause's *kind* by rewriting its key (`join`/`inner_join` ↔ `left_join`, plus
  # `left_join`↔`right_join` under a `RIGHT`-capable dialect and `*`→`full_join` under a
  # `FULL`-capable one), keeping the join's value (`c in assoc(p, :x)`). One mutant per enabled
  # target.
  defp join_swaps(meta, source, clauses, opts) do
    flips = join_flips(opts)

    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      for to <- Map.get(flips, clause_key(pair), []) do
        {:from, meta,
         [source, List.replace_at(clauses, index, put_key(pair, AST.keyword_key(to)))]}
      end
    end)
  end

  # The portable flips, plus each dialect-gated map whose dialects `opts` enables (`RIGHT`,
  # `FULL`). Independently gated, so a config can enable one without the other.
  defp join_flips(opts) do
    @portable_join_flips
    |> maybe_merge(@right_join_flips, Config.dialect_enabled?(opts, @right_join_dialects))
    |> maybe_merge(@full_join_flips, Config.dialect_enabled?(opts, @full_join_dialects))
  end

  defp maybe_merge(flips, _added, false), do: flips
  # mutare:ignore[operand_swap] merge order is irrelevant — targets are consumed as a set
  defp maybe_merge(flips, added, true), do: Map.merge(flips, added, fn _k, a, b -> a ++ b end)

  # Swap each aggregate inside a `select`/`select_merge`/`order_by` clause value — one mutant per
  # aggregate position (`Mutare.Ecto.Aggregate`). A `having` aggregate is deliberately *not* here:
  # its condition is hosted (`^`/`dynamic`), so the swap rides the host alongside the operator swaps
  # (`Mutare.Ecto.Host.catalog/3`) rather than being delivered as a whole-`from` rewrite.
  defp aggregate_swaps(meta, source, clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      if clause_key(pair) in @aggregate_keys do
        for swapped <- Aggregate.swaps(clause_value(pair)) do
          {:from, meta, [source, List.replace_at(clauses, index, put_value(pair, swapped))]}
        end
      else
        []
      end
    end)
  end

  # Flip each `order_by` clause's directions, reusing the shared ordering catalog — one mutant
  # per axis per direction key, tagged with its family (`:ordering` direction / `:ordering_nulls`
  # placement; see `Mutare.Ecto.Ordering`).
  defp order_flips(meta, source, clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      if clause_key(pair) == :order_by do
        for {family, flipped} <- Ordering.flips(clause_value(pair)) do
          {family,
           {:from, meta, [source, List.replace_at(clauses, index, put_value(pair, flipped))]}}
        end
      else
        []
      end
    end)
  end

  defp clause_key({key, _value}), do: AST.atom_value(key)

  # mutare:ignore[clause_drop] equivalent — a Sourceror-parsed from clause list is all `key: value` pairs, so the non-pair fallback is unreachable from valid Ecto
  defp clause_key(_node), do: nil

  defp clause_value({_key, value}), do: value
  defp put_value({key, _old}, value), do: {key, value}
  defp put_key({_key, value}, key), do: {key, value}
end
