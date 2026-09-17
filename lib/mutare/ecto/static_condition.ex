defmodule Mutare.Ecto.StaticCondition do
  @moduledoc """
  The condition Ecto accepts only **statically built**, and its whole-call delivery.

  The host delivers a `where`/`having` condition's mutants by weaving: the condition becomes a
  `^`-pinned `dynamic/2` (`Mutare.Ecto.Host`). That changes how Ecto builds the clause — from
  the compile-time filter builder to the runtime dynamic path — and the two do not accept the
  same expressions. A subquery in a `having` is where they part:

      from p in "posts",
        group_by: p.user_id,
        having: count(p.id) > subquery(from t in "thresholds", select: max(t.value))

  Written statically this is valid; as `having: ^dynamic([p], …)` Ecto raises "subqueries are
  not allowed in `having` expressions". It raises when the query is **built**, not when the
  module compiles, and it raises on the woven *original* branch as readily as on a mutant — so
  weaving it would break the unmutated code path of every test that reaches the function.

  ## The rule

  Whether a condition can be woven depends on **both** the clause receiving it and the
  expression (`weavable?/2`): it can unless the expression carries a subquery
  (`Mutare.Ecto.Subquery.present?/1`) *and* the clause rejects one in a dynamic
  (`Mutare.Ecto.Surface.dynamic_subqueries?/1` — everything but `where`/`or_where`). The host
  declines exactly the predicates this rule refuses, and `mutations/2` serves exactly those, so
  each condition is delivered once: woven, or rebuilt here.

  Only a **predicate** is either's (`Mutare.Ecto.Host.Condition.shape/1`). A keyword filter
  carries a subquery as readily (`having: [score: subquery(…)]` — Ecto's filter builder
  accumulates a pair value's), but the weave would carry nothing for it — its pairs are routed
  to core one by one — so neither is this module's rebuild, which would otherwise read the list
  as a predicate and rename its column keys.

  ## Delivery

  Hosting is a delivery optimization, not a semantic category. The mutants are the ones the
  weave would have carried — the plugin's own catalog (`Mutare.Ecto.Host.Catalog.own_catalog/2`)
  and the `^`-pin interiors sub-contracted to core (`Mutare.Ecto.Island`) — each delivered as
  the **whole call** rebuilt around one mutated condition, through Mutare's ordinary in-place
  selector (the delivery `Mutare.Ecto.Dynamic` and `Mutare.Ecto.Query` use). Every selector
  branch is then a statically built clause, which Ecto accepts. A catalog mutant still reports
  at the expression it changed (`Mutare.Ecto.Walk` anchors it); a pin-interior mutant reports at
  the whole call, as it does from `Mutare.Ecto.Dynamic`. The `families:` filter and equivalence
  notes apply as on any `mutate/2` path.

  The rule follows Ecto's current behaviour without depending on it: were a later Ecto to accept
  the dynamic form, this delivery would remain valid, only more verbose than the weave.
  """

  alias Mutare.Ecto.{Context, Island, Subquery, Surface, Tag}
  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.Host.{Catalog, Condition}

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Whether the host can weave `condition` into `clause` (a condition macro's name or a `from`
  clause key) as a `^`-pinned `dynamic/2` — see "The rule" in the moduledoc.
  """
  @spec weavable?(atom(), Macro.t()) :: boolean()
  def weavable?(clause, condition),
    do: Surface.dynamic_subqueries?(clause) or not Subquery.present?(condition)

  @doc """
  Every single-point mutant of each condition in `call` the host declines under `weavable?/2`,
  as the **whole call** rebuilt around the mutated condition — a condition macro
  (`having(q, [p], …)`, direct or piped) or a `from`'s keyword clauses. `[]` for a call with no
  such condition, which is nearly every call.
  """
  @spec mutations(QueryCall.t(), Context.t()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
  @impl Mutare.Ecto.SubMutator
  def mutations(%QueryCall{name: :from} = call, context) do
    case FromCall.parse(call) do
      %FromCall{clauses: clauses} = from ->
        KeywordList.flat_map(clauses, &Surface.from_clause?(&1, :hosted), fn entry, index ->
          rebuilt(entry.key, entry.value, context, fn mutated ->
            from |> FromCall.replace_clause(index, mutated) |> FromCall.to_ast()
          end)
        end)

      nil ->
        []
    end
  end

  def mutations(%QueryCall{name: macro, args: args} = call, context) do
    case Condition.locate(args) do
      %Condition{node: condition, index: index} ->
        rebuilt(macro, condition, context, &QueryCall.replace_arg(call, index, &1))

      nil ->
        []
    end
  end

  # The weave's own mutant set (`Mutare.Ecto.Host.Catalog.mutants/2`'s two halves), each
  # delivered through `rebuild` instead — for a predicate the host declined, and only for one.
  # (A condition macro's argument is already one: `Condition.locate/1` reads the same shape.)
  defp rebuilt(clause, condition, %Context{config: config} = context, rebuild) do
    if declined?(clause, condition) do
      own = for tag <- Catalog.own_catalog(condition, config), do: Tag.map_node(tag, rebuild)

      # mutare:ignore[operand_swap] equivalent — two independent mutant lists, consumed as a set
      own ++ Island.subcontracted(condition, context, rebuild)
    else
      []
    end
  end

  defp declined?(clause, condition),
    do: Condition.shape(condition) == :predicate and not weavable?(clause, condition)
end
