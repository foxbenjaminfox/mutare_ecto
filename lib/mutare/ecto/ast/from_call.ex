defmodule Mutare.Ecto.AST.FromCall do
  @moduledoc false
  # A normalized `from` call — `from(source)` or `from(source, clauses)`, and their piped twins
  # `source |> from()` / `source |> from(clauses)`, which core hands over as the direct call —
  # read apart into the resolved call (`Mutare.Ecto.AST.QueryCall`), its source, and its keyword
  # clause list (`Mutare.Ecto.AST.KeywordList`; empty for the clause-less form). The **one** place
  # the plugin takes that shape apart and puts it back together: the whole-`from` rewrites
  # (`Mutare.Ecto.Query`), the subquery interior walks (`Mutare.Ecto.Subquery`), the selector host
  # and its splice (`Mutare.Ecto.Host`/`Host.Target`), and — through the identity-free
  # `parse_args/1` — the routing classifier (`Mutare.Ecto.Host.Routing`).
  #
  # The source is argument 0 in both spellings, and every edit — the source's replacement
  # included — rebuilds through the call's own `rebuild`, which core renders in the written
  # form (a pipe stays a pipe in the report).
  #
  # Every edit (`replace_source/2`, `replace_clause/3`, `rekey_clause/3`, `delete_clauses/2`)
  # returns a new value, so edits compose; `to_ast/1` renders through the call's own `rebuild`,
  # keeping the written form (bare/qualified/aliased, direct/piped). This module owns two
  # `from`-shape rules: which written clauses are **effective** (`effective_clause?/2` — a
  # last-wins key's overridden occurrence never reaches the built query), and the empty-list
  # collapse: a `from` whose clause list is **empty** renders as the single-argument
  # `from(source)` — or the argless `source |> from()` — never `from(source, [])`. The two are
  # semantically identical, but the empty keyword-args list is both noisier and — nested inside a
  # subquery expression (`exists(from(c, []))`) — unrenderable by the Elixir formatter, so the
  # clean form is the only safe shape. The list is empty only when the `from` was written
  # clause-less or a drop removed its last clause; every swap replaces a clause, keeping it
  # non-empty.

  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.Surface

  @enforce_keys [:call, :source, :clauses]
  defstruct [:call, :source, :clauses]

  @type t :: %__MODULE__{call: QueryCall.t(), source: Macro.t(), clauses: KeywordList.t()}

  @doc """
  The normalized `from` for a resolved `Ecto.Query.from` call — a `QueryCall`, or a stamped node
  `QueryCall.parse/1` resolves — or `nil` for any other call, and for a `from` whose clause
  argument is not a keyword list (`from(p in Post, ^clauses)`).
  """
  @spec parse(QueryCall.t() | Macro.t()) :: t() | nil
  def parse(%QueryCall{name: :from, args: args} = call) do
    case parse_args(args) do
      {source, %KeywordList{} = clauses} ->
        %__MODULE__{call: call, source: source, clauses: clauses}

      nil ->
        nil
    end
  end

  def parse(%QueryCall{}), do: nil

  def parse(node) do
    case QueryCall.parse(node) do
      %QueryCall{} = call -> parse(call)
      nil -> nil
    end
  end

  @doc """
  Read `{source, clauses}` from a `from`'s arguments (the piped source included, at position 0).
  Malformed arities and non-keyword clauses return `nil`. Routing uses this before the
  arguments have been resolved.
  """
  @spec parse_args([Macro.t()]) :: {Macro.t(), KeywordList.t()} | nil
  def parse_args([source]), do: {source, KeywordList.empty()}
  def parse_args([source, clauses]), do: with_clauses(source, clauses)
  def parse_args(_args), do: nil

  defp with_clauses(source, clauses) do
    case KeywordList.parse(clauses) do
      %KeywordList{} = clauses -> {source, clauses}
      nil -> nil
    end
  end

  @doc """
  Whether the clause at `index` **reaches the built query**. Ecto applies a `from`'s keyword pairs
  in written order, and a *last-wins* key (`Mutare.Ecto.Surface.last_wins?/1` —
  `limit`/`offset`/`lock`) replaces its predecessor where every other key accumulates: of
  `limit: 5, limit: 10` only the `10` is ever in the query. So every clause is effective except
  a last-wins key's non-final occurrence. A mutation of an ineffective clause — its drop, its
  bound bump — leaves the built query unchanged, an equivalent mutant by construction, so the
  whole-`from` producers (`Mutare.Ecto.Query`) and the host (`Mutare.Ecto.Host`) skip it; the
  final occurrence keeps every mutant, and its drop is live (it uncovers the previous one).

  Only the `from` keyword form is in view: a bound repeated across a pipe
  (`q |> limit(5) |> limit(10)`) or across functions composes at runtime, where no single node
  sees both occurrences, so those stay mutated.
  """
  @spec effective_clause?(t(), non_neg_integer()) :: boolean()
  def effective_clause?(%__MODULE__{clauses: %KeywordList{entries: entries} = clauses}, index) do
    %KeywordList.Entry{key: key} = Enum.at(entries, index)
    not Surface.last_wins?(key) or KeywordList.last_of_key?(clauses, index)
  end

  @doc "Replace the source, keeping its clauses."
  @spec replace_source(t(), Macro.t()) :: t()
  def replace_source(%__MODULE__{} = from, source), do: %{from | source: source}

  @doc "The `from` with `value` as the value of the clause at `index` — its key and every other clause kept."
  @spec replace_clause(t(), non_neg_integer(), Macro.t()) :: t()
  def replace_clause(%__MODULE__{clauses: clauses} = from, index, value),
    do: %{from | clauses: KeywordList.put_value(clauses, index, value)}

  @doc "The `from` with the clause at `index` re-keyed `key`, its value kept (a join-kind or set-operation swap)."
  @spec rekey_clause(t(), non_neg_integer(), atom()) :: t()
  def rekey_clause(%__MODULE__{clauses: clauses} = from, index, key),
    do: %{from | clauses: KeywordList.put_key(clauses, index, key)}

  @doc "The `from` without the clauses at `indices`."
  @spec delete_clauses(t(), [non_neg_integer()]) :: t()
  def delete_clauses(%__MODULE__{clauses: clauses} = from, indices),
    do: %{from | clauses: KeywordList.delete_at(clauses, indices)}

  @doc """
  Render the `from` back to AST through the call's own `rebuild`, keeping the written form. An
  empty clause list collapses to the clause-less form (see the module comment).
  """
  @spec to_ast(t()) :: Macro.t()
  def to_ast(%__MODULE__{call: call, source: source, clauses: clauses}) do
    QueryCall.rebuild(call, [source | visible_clauses(clauses)])
  end

  defp visible_clauses(%KeywordList{entries: []}), do: []
  defp visible_clauses(clauses), do: [KeywordList.to_ast(clauses)]
end
