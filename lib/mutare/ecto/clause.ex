defmodule Mutare.Ecto.Clause do
  @moduledoc """
  Standalone/pipe clause-macro mutations — the composable counterparts of the whole-`from` family
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
    * **JoinType** — `join(q, :left, [p], c in Comment, on: …)` / `q |> join(:full, …)`: narrow
      the join's kind by swapping its written **qualifier** (`:left`→`:inner`,
      `:full`→`:left`/`:right`, and `:left`↔`:right` under a `RIGHT`-capable dialect), via the
      shared `Mutare.Ecto.JoinType` catalog — the same flips, under the same policy and
      `dialects:` gate, as `Mutare.Ecto.Query`'s `left_join:` key swap. Only a literal qualifier
      is swapped: a computed one (`join(q, kind, …)`) is a value mutated where it is bound.

  These macros route through the `:routing` classifier (`Mutare.Ecto.Host.Routing`), which keeps
  their *data* positions raw while the routed node is still offered whole to `mutate/2`; the
  mutation uses Mutare's ordinary in-place selector, since the macro call is itself an
  expression. The orthogonal **stage removal** (`q |> order_by(…)` → `q`) lives in
  `Mutare.Ecto.ClauseDrop`, and the `:bound` ±1 bump of a literal `limit`/`offset` is hosted
  pin-only (`Mutare.Ecto.Bound`; NOTES "Bound bump: from whole-call rewrite to pin-only
  hosting").

  A value capability's mutated position is always the **last argument** (the ordering / the
  selector), which is true for both the direct form (`order_by(q, binds, ordering)`) and the
  pipe form (`q |> order_by(binds, ordering)`, where `q` is the piped left side, not in `args`)
  — so it needs no pipe-mode bookkeeping. The join qualifier is instead the call's *second*
  argument, which the call's `pipe_mode` places among the visible ones.
  """

  alias Mutare.Ecto.{AST, Combination, Context, JoinType, Surface, Tag, ValueCatalog}
  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Mutator.Mutation

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Standalone/pipe clause-macro mutations for `node` as self-tagging `Mutare.Ecto.Tag`s
  (a swap family — order/aggregate — carries the finer operator/kind label), or `[]`.
  """
  @spec mutations(QueryCall.t(), Context.t()) :: [Mutare.Ecto.SubMutator.tagged()]
  @impl Mutare.Ecto.SubMutator
  # Receives the Dispatcher-normalized call (`Mutare.Ecto.SubMutator`). The `args: []` clause
  # protects the `{init, [last]} = Enum.split(args, -1)` destructuring on a degenerate zero-arg
  # macro node.
  def mutations(%QueryCall{args: []}, _context), do: []

  def mutations(%QueryCall{name: macro} = call, %Context{config: config}) do
    capabilities = Surface.mutations(macro)
    position = ValueCatalog.position(capabilities)

    Enum.flat_map(capabilities, &capability_mutations(&1, call, position, config))
  end

  # `:combination` renames the call and `:join_type` swaps its qualifier; every other capability
  # mutates its last-argument *value* through the shared dispatch (`Mutare.Ecto.ValueCatalog` —
  # the same one `Mutare.Ecto.Query` rebuilds a `from` clause with), in the position the macro's
  # capabilities declare. Only the join swap is `dialects:`-gated, so only it reads `config`.
  defp capability_mutations(:combination, call, _position, _config), do: combination_swaps(call)

  defp capability_mutations(:join_type, call, _position, config),
    do: qualifier_swaps(call, config)

  defp capability_mutations(capability, call, position, _config),
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

  # `join(query, qualifier, …)`: the qualifier's position counting the threaded query, which
  # `Mutare.Mutator.visible_index/2` places among the visible arguments — second written
  # directly, first when the query is piped in.
  @qualifier_position 1

  # Swap a standalone `join`'s kind by rewriting its written qualifier to each target the shared
  # `Mutare.Ecto.JoinType` catalog enables, keeping every other argument — the standalone twin of
  # `Mutare.Ecto.Query`'s clause-key swap, reported at the qualifier as that one is at the key.
  # `AST.atom_value/1` is `nil` for anything but a literal atom — a computed qualifier, or the
  # missing argument of a degenerate call — and `nil` is no flip source, so this is total.
  defp qualifier_swaps(%QueryCall{args: args, pipe_mode: pipe_mode} = call, config) do
    index = Mutare.Mutator.visible_index(@qualifier_position, pipe_mode)
    written = Enum.at(args, index)
    qualifier = AST.atom_value(written)

    for to <- JoinType.targets(qualifier, config) do
      swapped = Mutare.AST.literal(to)

      Tag.new(
        :join_type,
        QueryCall.replace_arg(call, index, swapped),
        JoinType.label(qualifier),
        Mutation.at(written, swapped)
      )
    end
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
