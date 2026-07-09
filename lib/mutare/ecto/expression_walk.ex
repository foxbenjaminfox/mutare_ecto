defmodule Mutare.Ecto.ExpressionWalk do
  @moduledoc false
  # The shared structural walker under the expression catalogs (`Mutare.Ecto.Aggregate`,
  # `Mutare.Ecto.Scalar`): given an arbitrary query-expression shape — a bare call, a tuple, a
  # list, a map or keyword list of them — and a `local` catalog producing the tagged alternatives
  # of *one* node, `walk/2` returns every **single-point** mutant: the whole expression with
  # exactly one position replaced by one of `local`'s alternatives, threading each mutant's
  # family/label (`Mutare.Ecto.Tag`) up unchanged while rebuilding its node.
  #
  # Descent follows the same author-macro rule as `Mutare.Ecto.Fragment`, shared through
  # `Mutare.Ecto.Descent`: a nested macro the author wrote may invent its own argument grammar
  # (Mutare mutates source, not expansions), so a call's argument is descended **only** when it is
  # plainly standard syntax — a non-macro node or an argument the macro routed `:expression`.

  alias Mutare.Ecto.{Descent, Tag}

  @typedoc "The per-node catalog: the tagged alternatives of one node, no descent."
  @type local :: (Macro.t() -> [Tag.t()])

  @doc "Every single-point mutant of `expr` under the `local` per-node catalog."
  @spec walk(Macro.t(), local()) :: [Tag.t()]
  # An interpolation island (`^expr`) is ordinary Elixir evaluated at runtime — outside every SQL
  # catalog's competence, so never offered and never descended. (In a hosted condition the host
  # sub-contracts the interior to core's generation; in these in-place `select`/`order_by` walks
  # the interior is left alone rather than wrongly mutated under an SQL rationale.)
  def walk({:^, _meta, _args}, _local), do: []

  # A call/operator node (atom form or a remote `{:., …}` form): offer the node's own alternatives,
  # then descend into its arguments so a nested position is reached too.
  def walk({form, meta, args} = node, local) when is_list(args) do
    # mutare:ignore[operand_swap] local/descend order is irrelevant — mutants are consumed as a set
    local.(node) ++ lift_args(form, meta, args, local)
  end

  # A 2-tuple literal — a `{a, b}` select, or a keyword/map pair: descend into both sides.
  def walk({left, right}, local) do
    # mutare:ignore[operand_swap] branch order is irrelevant — mutants are consumed as a set
    for(tag <- walk(left, local), do: Tag.map_node(tag, &{&1, right})) ++
      for(tag <- walk(right, local), do: Tag.map_node(tag, &{left, &1}))
  end

  # A list — a list select, the args of a `%{}`/`{}` node, or a keyword list: descend per element.
  def walk(list, local) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, i} ->
      for tag <- walk(el, local), do: Tag.map_node(tag, &List.replace_at(list, i, &1))
    end)
  end

  # Atoms, literals, variables, field references: nothing to offer, nothing to descend.
  def walk(_node, _local), do: []

  # Descend into a call/operator's arguments, but only where the argument is plainly standard
  # syntax we can mutate (`Mutare.Ecto.Descent`) — e.g. a `select: clamp(sum(p.x), 10)` whose
  # `clamp/2` is registered `:skip` never has its `sum` swapped, because we don't know that
  # `sum(p.x)` even means an aggregate to `clamp`.
  defp lift_args(form, meta, args, local) do
    Descent.each_arg({form, meta, args}, fn arg, i ->
      for tag <- walk(arg, local),
          do: Tag.map_node(tag, &{form, meta, List.replace_at(args, i, &1)})
    end)
  end
end
