defmodule Mutare.Ecto.AST.FromCall do
  @moduledoc false
  # A normalized `from` call — `from(source)` or `from(source, clauses)` — read apart into the
  # resolved call (`Mutare.Ecto.AST.QueryCall`), its source, and its keyword clause list
  # (`Mutare.Ecto.AST.KeywordList`; empty for the clause-less form). The **one** place the plugin
  # takes that shape apart and puts it back together: the whole-`from` rewrites
  # (`Mutare.Ecto.Query`), the subquery interior walks (`Mutare.Ecto.Subquery`), the selector host
  # and its splice (`Mutare.Ecto.Host`/`Host.Target`), and — through the identity-free
  # `parse_args/1` — the routing classifier (`Mutare.Ecto.Host.Routing`).
  #
  # Every edit (`replace_source/2`, `replace_clause/3`, `rekey_clause/3`, `delete_clauses/2`)
  # returns a new value, so edits compose; `to_ast/1` renders through the call's own `rebuild`,
  # keeping the written form (bare/qualified/aliased), and owns the one shape rule: a `from` whose
  # clause list is **empty** renders as the single-argument `from(source)`, never
  # `from(source, [])`. The two are semantically identical, but the empty keyword-args list is
  # both noisier and — nested inside a subquery expression (`exists(from(c, []))`) — unrenderable
  # by the Elixir formatter, so the clean single-arg form is the only safe shape. The list is empty
  # only when the `from` was written clause-less or a drop removed its last clause; every swap
  # replaces a clause, keeping it non-empty.

  alias Mutare.Ecto.AST.{KeywordList, QueryCall}

  @enforce_keys [:call, :source, :clauses]
  defstruct [:call, :source, :clauses]

  @type t :: %__MODULE__{call: QueryCall.t(), source: Macro.t(), clauses: KeywordList.t()}

  @doc """
  The normalized `from` for a resolved `Ecto.Query.from` call — a `QueryCall`, or a stamped node
  `QueryCall.parse/1` resolves — or `nil` for any other call, and for a `from` whose second
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
  The `{source, clauses}` shape of a `from` **argument list** — `from(source)` yields an empty
  clause list, `from(source, clauses)` the parsed keyword list — or `nil` for any other shape (a
  non-keyword second argument, or a malformed arity). The identity-free half of `parse/1`: the
  routing classifier reads it before descent has stamped the call.
  """
  @spec parse_args([Macro.t()]) :: {Macro.t(), KeywordList.t()} | nil
  def parse_args([source]), do: {source, KeywordList.empty()}

  def parse_args([source, clauses]) do
    case KeywordList.parse(clauses) do
      %KeywordList{} = clauses -> {source, clauses}
      nil -> nil
    end
  end

  def parse_args(_args), do: nil

  @doc "The `from` with `source` in place of its written source, the clauses untouched."
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
  empty clause list collapses to the single-argument `from(source)` (see the module comment).
  """
  @spec to_ast(t()) :: Macro.t()
  def to_ast(%__MODULE__{call: call, source: source, clauses: %KeywordList{entries: []}}),
    do: QueryCall.rebuild(call, [source])

  def to_ast(%__MODULE__{call: call, source: source, clauses: clauses}),
    do: QueryCall.rebuild(call, [source, KeywordList.to_ast(clauses)])
end
