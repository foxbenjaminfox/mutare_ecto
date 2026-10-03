defmodule Mutare.Ecto.Island.Policy do
  @moduledoc false
  # Structural policy for a subcontracted Elixir interior. The pin's role comes from
  # `Mutare.Ecto.Fragment`; generation and delivery belong to `Mutare.Ecto.Island`.

  alias Mutare.Ecto.{AST, Fragment}
  alias Mutare.Mutator.Spec

  @doc """
  Whether a producer's rewrite preserves the literals held by the island's role.

  A pin moves a value out of SQL, but its position still determines what that value means:
  `p.status == ^:score` holds data, while `field(p, ^:score)` names a column.

    * `:value` holds nothing: the interior is application data.
    * `:condition` holds every keyword key in the interior. Ecto reads a root pin's keyword
      list as a field filter, so renaming or deleting its keys can break the query. This
      extends the written shorthand's key protection in `Mutare.Ecto.Host.Routing` to
      computed filters such as `^(if flag, do: [active: true], else: [])`.
    * `:structural` holds literals known to reach the result: atoms, strings and module
      aliases; list and tuple elements; a block's final expression; either operand of `||`;
      and result branches of `if`, `unless`, `case` and `cond`. Conditions, patterns and
      arbitrary call arguments are not known results and remain mutable.

  This is a whole-interior **set comparison**, not data-flow analysis. It deliberately
  over-approximates a condition's structure: keys in an incidental option list are held too.
  Conversely, it misses names returned through calls, such as `Keyword.get/3`'s default.
  Sets also ignore multiplicity and location: removing one occurrence or changing one branch
  passes if another occurrence preserves the same key/name. Such mutants can still break
  the query; the policy only rejects changes it can recognize by this approximation.

  Mutants produced by `Mutare.Ecto` bypass the comparison: its SQL catalogs already respect
  query structure, and an inner `from`'s legitimate `where:` drop changes the key set. The
  exemption uses the producer's module, regardless of its report name (`:as`). Core and
  third-party producers remain subject to the comparison, even when named `:ecto`.
  """
  @spec allows?(Spec.t(), Fragment.role(), Macro.t(), Macro.t()) :: boolean()
  def allows?(%Spec{module: Mutare.Ecto}, _role, _original, _mutated), do: true

  def allows?(%Spec{}, role, original, mutated),
    do: held(role, mutated) == held(role, original)

  # No fallback: a new role needs an explicit policy.
  defp held(:value, _interior), do: MapSet.new()
  defp held(:condition, interior), do: keyword_keys(interior)
  defp held(:structural, interior), do: interior |> result_literals() |> MapSet.new()

  # The keyword-list keys anywhere in `ast`.
  defp keyword_keys(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn node, acc ->
        if Mutare.AST.keyword_label?(node),
          do: {node, [Mutare.AST.key_atom(node) | acc]},
          else: {node, acc}
      end)

    MapSet.new(keys)
  end

  # The name rule's reader: the written literals `ast` can evaluate
  # **to**, one clause per form the rule lists. Every other form — a variable, a call and its
  # arguments, an interpolated string — computes its value by means this reader does not know,
  # and yields nothing.
  defp result_literals({:__block__, _meta, [literal]})
       when is_atom(literal) or is_binary(literal),
       do: [literal]

  defp result_literals({:__aliases__, _meta, _segments} = module),
    do: [Sourceror.strip_meta(module)]

  defp result_literals({:__block__, _meta, [elements]}) when is_list(elements),
    do: Enum.flat_map(elements, &result_literals/1)

  defp result_literals({:__block__, _meta, [{left, right}]}),
    do: result_literals(left) ++ result_literals(right)

  defp result_literals({:__block__, _meta, [_, _ | _] = statements}),
    do: statements |> List.last() |> result_literals()

  defp result_literals({:{}, _meta, elements}), do: Enum.flat_map(elements, &result_literals/1)
  defp result_literals({left, right}), do: result_literals(left) ++ result_literals(right)

  defp result_literals({:||, _meta, [left, right]}),
    do: result_literals(left) ++ result_literals(right)

  defp result_literals({branching, _meta, [_ | _] = args})
       when branching in [:if, :unless, :case, :cond] do
    for {_do_or_else, body} <- AST.unwrap_list(List.last(args)) || [],
        literal <- branch_literals(body),
        do: literal
  end

  defp result_literals(_computed), do: []

  # A `do`/`else` body: the `->` clauses of a `case`/`cond` (each clause's right side), or the
  # one expression of an `if`/`unless`.
  defp branch_literals(clauses) when is_list(clauses),
    do: for({:->, _meta, [_head, body]} <- clauses, literal <- result_literals(body), do: literal)

  defp branch_literals(body), do: result_literals(body)
end
