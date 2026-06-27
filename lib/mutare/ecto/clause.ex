defmodule Mutare.Ecto.Clause do
  @moduledoc """
  Standalone/pipe clause-macro mutations — the composable cousins of the whole-`from` family
  in `Mutare.Ecto.Query`. Where `Query` mutates `from`'s keyword clauses, this mutates the
  same kinds of thing written as standalone calls or pipe stages:

    * **Ordering** — `order_by(q, [u], asc: u.name)` / `q |> order_by(asc: u.name)`: flip a
      sort direction (`:asc`↔`:desc`, nulls-placement variants), via the shared
      `Mutare.Ecto.Ordering` catalog.
    * **Bound** — `limit(q, 10)` / `q |> offset(5)`: bump the literal value by `±1`
      (non-negative only).
    * **Aggregate** — `select(q, [u], sum(u.amount))` / `q |> select_merge(%{n: max(u.x)})`, and
      an aggregate written into an `order_by` (`q |> order_by([u], desc: sum(u.amount))`): swap the
      aggregate (`sum`↔`avg`, `min`↔`max`), via the shared `Mutare.Ecto.Aggregate` walker. (A
      `having` aggregate is hosted instead — `Mutare.Ecto.Host`.)

  These macros are registered through the `:routing` classifier (`Mutare.Ecto.Host`), which keeps
  their *data* positions (binding list, ordering, bound, selector) raw — so core never descends a
  binding/expression into them — while marking the threaded query an `:expression`. A routed macro
  node is still offered to every mutator's `mutate/1` — exactly like a `from` node — and the
  mutation rides Mutare's ordinary in-place selector. No host is needed: the macro call is itself
  an expression, so the selector `case` can wrap it whole. The orthogonal **stage removal**
  (`q |> order_by(…)` → `q`) lives in `Mutare.Ecto.ClauseDrop`.

  The mutated position is always the **last argument** (the ordering / the bound value), which
  is true for both the direct form (`order_by(q, binds, ordering)`) and the pipe form
  (`q |> order_by(binds, ordering)`, where `q` is the piped left side, not in `args`) — so no
  pipe-mode bookkeeping is required.
  """

  alias Mutare.Ecto.{Aggregate, AST, Ordering, Surface}

  @behaviour Mutare.Ecto.SubMutator

  @ordering_macros Surface.ordering_macros()
  @bound_macros Surface.bound_macros()
  @aggregate_macros Surface.aggregate_macros()

  @doc "Standalone/pipe clause-macro mutations for `node` as `{family, node}` pairs, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [{atom(), Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  # Normalize the call (`Mutare.Ecto.AST.query_macro_call/1`) so the qualified (`Ecto.Query.order_by`)
  # and aliased (`Q.order_by`) forms mutate exactly like the bare/imported one; `rebuild` re-emits each
  # mutant in the source's written form. Each clause guards `args != []` to protect the
  # `{init, [last]} = Enum.split(args, -1)` destructuring on a degenerate zero-arg macro node.
  def mutations(node, _context) do
    case AST.query_macro_call(node) do
      {macro, args, rebuild} when macro in @ordering_macros and args != [] ->
        order_by_mutations(macro, args, rebuild)

      {macro, args, rebuild} when macro in @bound_macros and args != [] ->
        bound_mutations(macro, args, rebuild)

      {macro, args, rebuild} when macro in @aggregate_macros and args != [] ->
        select_mutations(macro, args, rebuild)

      _ ->
        []
    end
  end

  defp order_by_mutations(macro, args, rebuild) do
    mutate_last(macro, args, rebuild, fn ordering ->
      # mutare:ignore[operand_swap] direction flips and aggregate swaps are consumed as a set — order is irrelevant
      Ordering.flips(ordering) ++ Aggregate.swaps(ordering)
    end)
  end

  defp bound_mutations(macro, args, rebuild),
    do: mutate_last(macro, args, rebuild, &bound_flips/1)

  defp select_mutations(macro, args, rebuild),
    do: mutate_last(macro, args, rebuild, &Aggregate.swaps/1)

  # The shape all three clause-macro mutators share: split the mutated **last argument** off (the
  # ordering / bound / selector — `init` keeps the binding list when one is written), map it to
  # `{family, mutated}` pairs via `catalog`, and rebuild the call around each, keeping the source's
  # written form. The `args != []` guard in `mutations/2` makes the `[last]` destructure total.
  defp mutate_last(macro, args, rebuild, catalog) do
    {init, [last]} = Enum.split(args, -1)
    for {family, mutated} <- catalog.(last), do: {family, rebuild.(macro, init ++ [mutated])}
  end

  # `limit`/`offset` boundary bumps as `{:bound, literal}` pairs: bump a literal integer by `±1`
  # (non-negative only). A `^pinned`/expression bound has no literal here, so it yields nothing —
  # its value is mutated where it is bound, in ordinary Elixir.
  defp bound_flips(value) do
    case AST.int_value(value) do
      nil -> []
      n -> for bumped <- AST.bumps(n), do: {:bound, AST.int_literal(bumped)}
    end
  end
end
