defmodule Mutare.Ecto.StaticCondition do
  @moduledoc """
  The condition the host cannot weave, and its whole-call delivery.

  The host delivers a hosted condition's mutants by weaving: the condition becomes a
  `^`-pinned `dynamic/2` that re-declares the condition's bindings (`Mutare.Ecto.Host`). Two
  kinds of condition cannot take that form, though each is valid as written.

  **A subquery in a `having`.** Weaving changes how Ecto builds the clause — from the
  compile-time filter builder to the runtime dynamic path — and the two do not accept the same
  expressions:

      from p in "posts",
        group_by: p.user_id,
        having: count(p.id) > subquery(from t in "thresholds", select: max(t.value))

  Written statically this is valid; as `having: ^dynamic([p], …)` Ecto raises "subqueries are
  not allowed in `having` expressions". It raises when the query is **built**, not when the
  module compiles, and it raises on the woven *original* branch as readily as on a mutant — so
  weaving it would break the unmutated code path of every test that reaches the function.

  **A binding declaration the plugin cannot re-declare** — a computed index (`[{p, index}]`) or
  an interpolated name that calls a function (`[{^name(), p}]`), each of which a re-declaration
  would evaluate a second time (`Mutare.Ecto.Host.Bindings`). The woven `dynamic/2` has no
  faithful binding list to carry, and an empty one would leave the condition's variables
  unbound. A condition that is itself a `^` pin is the exception: it is woven pin-only, with no
  `dynamic/2` and so no bindings (`Mutare.Ecto.Host.Target`'s root-pin rule), whatever the
  declaration.

  ## The rule

  `delivery/4` decides, for one condition, from the clause receiving it, the expression, its
  predicate kind, and the declaration it is read under. A condition is **rebuilt** when the
  expression carries a subquery (`Mutare.Ecto.Subquery.present?/1`) that the clause rejects in a
  dynamic (`Mutare.Ecto.Surface.dynamic_subqueries?/1` — everything but `where`/`or_where`), or when
  it is not a `:root_pin` and its declaration does not read (`t:Mutare.Ecto.Host.Bindings.result/0`
  is `:error`); every other condition is **woven**. Both the host and `mutations/2` enumerate the
  same conditions (`Mutare.Ecto.Host.Condition`) and ask `delivery/4` of each, so each condition is
  delivered once: woven, or rebuilt here.

  Only a **predicate** is either's, and `Mutare.Ecto.Host.Condition` locates nothing else
  (`Mutare.Ecto.Host.Condition.shape/1`). A keyword filter carries a subquery as readily
  (`having: [score: subquery(…)]` — Ecto's filter builder accumulates a pair value's), and sits
  under an unread declaration as readily, but the weave would carry nothing for it — its pairs
  are routed to core one by one — so neither is this module's rebuild, which would otherwise
  read the list as a predicate and rename its column keys.

  ## Delivery

  Hosting is a delivery optimization, not a semantic category. The mutants are the ones the
  weave would have carried — the plugin's own catalog (`Mutare.Ecto.Host.Catalog.own_catalog/2`)
  and the `^`-pin interiors sub-contracted to core (`Mutare.Ecto.Island`) — each delivered as
  the **whole call** rebuilt around one mutated condition, through Mutare's ordinary in-place
  selector (the delivery `Mutare.Ecto.Dynamic` and `Mutare.Ecto.Query` use). Every selector
  branch is then a statically built clause under the written declaration, which Ecto accepts. A
  catalog mutant still reports at the expression it changed (`Mutare.Ecto.Walk` anchors it); a
  pin-interior mutant reports at the whole call, as it does from `Mutare.Ecto.Dynamic`. The
  `families:` filter and equivalence notes apply as on any `mutate/2` path.

  The subquery rule follows Ecto's current behaviour without depending on it: were a later Ecto
  to accept the dynamic form, this delivery would remain valid, only more verbose than the weave.
  """

  alias Mutare.Ecto.{Context, Island, Subquery, Surface, Tag}
  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Bindings, Catalog, Condition}

  @behaviour Mutare.Ecto.SubMutator

  @typedoc "How one hosted condition's mutants are delivered — see `delivery/4`."
  @type delivery :: {:woven, bindings :: [Macro.t()]} | :rebuilt

  @doc """
  How the host delivers `condition`, a predicate of `kind` (`Mutare.Ecto.Host.Condition.shape/1`)
  received by `clause` (a condition macro's name, a `from` clause key, or `:on`) under the
  declaration `bindings` reads as: `{:woven, list}`, carrying the binding list the woven
  `dynamic/2` re-declares (none for a `:root_pin`, which is woven without one), or `:rebuilt`, by
  `mutations/2` — see "The rule" in the moduledoc.
  """
  @spec delivery(atom(), Macro.t(), Condition.predicate_kind(), Bindings.result()) :: delivery()
  def delivery(clause, condition, kind, bindings) do
    if weavable?(clause, condition), do: woven(kind, bindings), else: :rebuilt
  end

  # A root pin's weave re-declares nothing, so its declaration is never read.
  defp woven(:root_pin, _bindings), do: {:woven, []}
  defp woven(:expression, {:ok, list}), do: {:woven, list}
  defp woven(:expression, :error), do: :rebuilt

  @doc """
  The half of `delivery/4` read off the clause and the expression alone: whether `clause`
  accepts `condition` as a `^`-pinned `dynamic/2` — false only for a subquery in a clause that
  rejects a dynamic one.
  """
  @spec weavable?(atom(), Macro.t()) :: boolean()
  def weavable?(clause, condition),
    do: Surface.dynamic_subqueries?(clause) or not Subquery.present?(condition)

  @doc """
  Every single-point mutant of each hosted condition in `call` that `delivery/4` rebuilds, as
  the **whole call** rebuilt around the mutated condition — a condition macro
  (`having(q, [p], …)`, direct or piped), a standalone `join`'s `on:`, or a `from`'s keyword
  clauses. `[]` for a call with no such condition, which is nearly every call.
  """
  @spec mutations(QueryCall.t(), Context.t()) :: [
          Mutare.Ecto.SubMutator.tagged() | Mutare.Mutator.Mutation.t()
        ]
  @impl Mutare.Ecto.SubMutator
  def mutations(%QueryCall{name: :from} = call, context) do
    case FromCall.parse(call) do
      %FromCall{source: source, clauses: clauses} = from ->
        conditions = Condition.from_indices(clauses)

        KeywordList.flat_map(clauses, fn %Entry{key: key, value: condition}, index ->
          case Map.fetch(conditions, index) do
            {:ok, kind} ->
              bindings = Bindings.from(source, Bindings.visible_to(clauses, index))

              rebuilt(key, condition, kind, bindings, context, fn mutated ->
                from |> FromCall.replace_clause(index, mutated) |> FromCall.to_ast()
              end)

            :error ->
              []
          end
        end)

      nil ->
        []
    end
  end

  # `Mutare.Ecto.Dispatcher` calls this for the `:from`, `:condition`, and `:join` kinds only.
  def mutations(%QueryCall{name: macro, args: args, pipe_mode: pipe_mode} = call, context) do
    case Surface.macro_kind(macro) do
      :condition ->
        condition_mutations(call, Condition.locate(:condition, args, pipe_mode), context)

      :join ->
        join_mutations(call, Condition.locate_on(args), context)
    end
  end

  defp condition_mutations(%QueryCall{name: macro} = call, %Condition{} = located, context) do
    %Condition{node: condition, index: index, kind: kind, declaration: declaration} = located
    bindings = Bindings.declarations(declaration)
    rebuilt(macro, condition, kind, bindings, context, &QueryCall.replace_arg(call, index, &1))
  end

  defp condition_mutations(_call, nil, _context), do: []

  defp join_mutations(
         %QueryCall{args: args} = call,
         {condition, kind, arg_index, pair_index},
         context
       ) do
    options = args |> Enum.at(arg_index) |> KeywordList.parse()

    rebuilt(:on, condition, kind, Bindings.join(args), context, fn mutated ->
      options = KeywordList.put_value(options, pair_index, mutated)
      QueryCall.replace_arg(call, arg_index, KeywordList.to_ast(options))
    end)
  end

  defp join_mutations(_call, nil, _context), do: []

  # The weave's own mutant set (`Mutare.Ecto.Host.Catalog.mutants/2`'s two halves), each
  # delivered through `rebuild` instead — for a predicate the host leaves to this module, and
  # only for one.
  defp rebuilt(clause, condition, kind, bindings, %Context{config: config} = context, rebuild) do
    case delivery(clause, condition, kind, bindings) do
      {:woven, _bindings} ->
        []

      :rebuilt ->
        own = for tag <- Catalog.own_catalog(condition, config), do: Tag.map_node(tag, rebuild)

        # mutare:ignore[operand_swap] equivalent — two independent mutant lists, consumed as a set
        own ++ Island.subcontracted(condition, context, rebuild)
    end
  end
end
