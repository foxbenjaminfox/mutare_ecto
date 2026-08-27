defmodule Mutare.Ecto.Clause do
  @moduledoc """
  Standalone/pipe clause-macro mutations — the composable cousins of the whole-`from` family
  in `Mutare.Ecto.Query`. Where `Query` mutates `from`'s keyword clauses, this mutates the
  same kinds of thing written as standalone calls or pipe stages:

    * **Ordering** — `order_by(q, [u], asc: u.name)` / `q |> order_by(asc: u.name)`: flip a
      sort direction (`:asc`↔`:desc`, nulls-placement variants), via the shared
      `Mutare.Ecto.Ordering` catalog.
    * **Aggregate** — `select(q, [u], sum(u.amount))` / `q |> select_merge(%{n: max(u.x)})`, and
      an aggregate written into an `order_by` (`q |> order_by([u], desc: sum(u.amount))`): swap the
      aggregate (`sum`↔`avg`, `min`↔`max`), via the shared `Mutare.Ecto.Aggregate` walker. (A
      `having` aggregate is hosted instead — `Mutare.Ecto.Host`.)
    * **Scalar** — `select(q, [u], u.price * u.qty)` / `q |> order_by([u], desc: u.a + u.b)` /
      `q |> select([u], coalesce(u.score, 0))`: mutate a value-computing form via the shared
      `Mutare.Ecto.Scalar` catalog — the arithmetic swaps (`+`↔`-`, `*`↔`/`) and the coalesce
      fallback drop. (The same forms in a `where`/`having` condition are hosted instead.)
    * **Combination** — `q |> intersect(^other)` / `except_all(q, ^other)`: swap the set
      operation by renaming the macro itself (`intersect`↔`except`, `intersect_all`↔`except_all`),
      via the shared `Mutare.Ecto.Combination` catalog. Unlike the others this mutates the
      call's *name*, not its last argument — the operand queries are untouched.

  These macros route through the `:routing` classifier (`Mutare.Ecto.Host.Routing`), which keeps
  their *data* positions raw while the routed node is still offered whole to `mutate/2`; the
  mutation rides Mutare's ordinary in-place selector, since the macro call is itself an
  expression. The orthogonal **stage removal** (`q |> order_by(…)` → `q`) lives in
  `Mutare.Ecto.ClauseDrop`, and the `:bound` ±1 bump of a literal `limit`/`offset` is hosted
  pin-only (`Mutare.Ecto.Bound`; NOTES "Bound bump: from whole-call rewrite to pin-only
  hosting").

  The mutated position is always the **last argument** (the ordering / the selector), which
  is true for both the direct form (`order_by(q, binds, ordering)`) and the pipe form
  (`q |> order_by(binds, ordering)`, where `q` is the piped left side, not in `args`) — so no
  pipe-mode bookkeeping is required.
  """

  alias Mutare.Ecto.{Combination, Surface, Tag, ValueCatalog}
  alias Mutare.Ecto.AST.QueryCall

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Standalone/pipe clause-macro mutations for `node` as self-tagging `Mutare.Ecto.Tag`s
  (a swap family — order/aggregate — carries the finer operator/kind label), or `[]`.
  """
  @spec mutations(QueryCall.t(), Mutare.Ecto.Context.t()) :: [Mutare.Ecto.SubMutator.tagged()]
  @impl Mutare.Ecto.SubMutator
  # Receives the Dispatcher-normalized call (`Mutare.Ecto.SubMutator`). The `args: []` clause
  # protects the `{init, [last]} = Enum.split(args, -1)` destructuring on a degenerate zero-arg
  # macro node.
  def mutations(%QueryCall{args: []}, _context), do: []

  def mutations(%QueryCall{name: macro} = call, _context) do
    capabilities = Surface.mutations(macro)
    position = ValueCatalog.position(capabilities)

    Enum.flat_map(capabilities, &capability_mutations(&1, call, position))
  end

  # `:combination` renames the call; every other capability mutates its last-argument *value*
  # through the shared dispatch (`Mutare.Ecto.ValueCatalog` — the same one `Mutare.Ecto.Query`
  # rebuilds a `from` clause with), in the position the macro's capabilities declare.
  defp capability_mutations(:combination, call, _position), do: combination_swaps(call)

  defp capability_mutations(capability, call, position),
    do: mutate_last(call, &ValueCatalog.mutants(capability, &1, position))

  # The shape the last-argument clause-macro mutators share: split the mutated **last argument**
  # off (the ordering / selector — `init` keeps the binding list when one is written), map it to
  # tagged mutants via `catalog`, and rebuild the call around each, keeping the source's written
  # form. Every catalog emits uniform `Mutare.Ecto.Tag`s, so the rebuilt entry threads the finer
  # label through. The `args != []` guard in `mutations/2` makes the `[last]` destructure total.
  defp mutate_last(%QueryCall{args: args} = call, catalog) do
    {init, [last]} = Enum.split(args, -1)

    for tag <- catalog.(last),
        do: Tag.map_node(tag, &QueryCall.rebuild(call, init ++ [&1]))
  end

  # Swap the set operation by renaming the macro call itself (`q |> intersect(^other)` →
  # `q |> except(^other)`), keeping every argument as written — the one clause mutation that
  # rewrites the call's *name* rather than its last argument (`Mutare.Ecto.Combination`). The
  # capability is only registered on the four flip-table names, so `swap/1` is total here.
  defp combination_swaps(%QueryCall{name: name} = call) do
    case Combination.swap(name) do
      nil -> []
      to -> [Tag.new(:combination, QueryCall.rename(call, to), Combination.label(name))]
    end
  end
end
