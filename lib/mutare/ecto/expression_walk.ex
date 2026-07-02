defmodule Mutare.Ecto.ExpressionWalk do
  @moduledoc false
  # The shared structural walker under the expression catalogs (`Mutare.Ecto.Aggregate`,
  # `Mutare.Ecto.Scalar`): given an arbitrary query-expression shape — a bare call, a tuple, a
  # list, a map or keyword list of them — and a `local` catalog producing the tagged alternatives
  # of *one* node, `walk/2` returns every **single-point** mutant: the whole expression with
  # exactly one position replaced by one of `local`'s alternatives, threading each mutant's
  # `{family, node, label}` tag up unchanged.
  #
  # Descent follows the same author-macro rule as `Mutare.Ecto.Fragment`: a nested macro the
  # author wrote may invent its own argument grammar (Mutare mutates source, not expansions), so
  # a call's argument is descended **only** when it is plainly standard syntax — a non-macro node
  # (`nil` routing) or an argument the macro routed `:expression` — read from the resolve-pass
  # stamp via `Mutare.Calls.macro_treatment/1`.

  alias Mutare.Calls

  @typedoc "One tagged single-point mutant: `{family, node, finer_label}`."
  @type tagged :: {atom(), Macro.t(), String.t()}

  @typedoc "The per-node catalog: the tagged alternatives of one node, no descent."
  @type local :: (Macro.t() -> [tagged()])

  @doc "Every single-point mutant of `expr` under the `local` per-node catalog."
  @spec walk(Macro.t(), local()) :: [tagged()]
  # A call/operator node (atom form or a remote `{:., …}` form): offer the node's own alternatives,
  # then descend into its arguments so a nested position is reached too.
  def walk({form, meta, args} = node, local) when is_list(args) do
    # mutare:ignore[operand_swap] local/descend order is irrelevant — mutants are consumed as a set
    local.(node) ++ lift_args(form, meta, args, local)
  end

  # A 2-tuple literal — a `{a, b}` select, or a keyword/map pair: descend into both sides.
  def walk({left, right}, local) do
    # mutare:ignore[operand_swap] branch order is irrelevant — mutants are consumed as a set
    for({f, m, l} <- walk(left, local), do: {f, {m, right}, l}) ++
      for({f, m, l} <- walk(right, local), do: {f, {left, m}, l})
  end

  # A list — a list select, the args of a `%{}`/`{}` node, or a keyword list: descend per element.
  def walk(list, local) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, i} ->
      for {f, m, l} <- walk(el, local), do: {f, List.replace_at(list, i, m), l}
    end)
  end

  # Atoms, literals, variables, field references: nothing to offer, nothing to descend.
  def walk(_node, _local), do: []

  # Descend into a call/operator's arguments, but only where the argument is plainly standard
  # syntax we can mutate (`descend_arg?/2` below) — e.g. a `select: clamp(sum(p.x), 10)` whose
  # `clamp/2` is registered `:skip` never has its `sum` swapped, because we don't know that
  # `sum(p.x)` even means an aggregate to `clamp`.
  defp lift_args(form, meta, args, local) do
    routing = Calls.macro_treatment({form, meta, args})

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, i} ->
      if descend_arg?(routing, i) do
        for {f, m, l} <- walk(arg, local), do: {f, {form, meta, List.replace_at(args, i, m)}, l}
      else
        []
      end
    end)
  end

  # Descend into an argument only when it is plainly standard syntax: a non-macro node (`nil`
  # routing) or a macro argument routed `:expression`. Every other treatment marks syntax whose
  # meaning is the macro's own, left raw — mirrors `Mutare.Ecto.Fragment.descend_arg?/2`.
  defp descend_arg?(nil, _index), do: true
  defp descend_arg?(routing, index), do: Enum.at(routing, index) == :expression
end
