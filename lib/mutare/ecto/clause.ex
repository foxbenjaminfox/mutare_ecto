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

  These macros are registered `:skip` (so core never descends a binding/expression into them),
  but a `:skip` macro node is still offered to every mutator's `mutate/1` — exactly like a
  `from` node — and the mutation rides Mutare's ordinary in-place selector. No host is needed:
  the macro call is itself an expression, so the selector `case` can wrap it whole.

  The mutated position is always the **last argument** (the ordering / the bound value), which
  is true for both the direct form (`order_by(q, binds, ordering)`) and the pipe form
  (`q |> order_by(binds, ordering)`, where `q` is the piped left side, not in `args`) — so no
  pipe-mode bookkeeping is required.
  """

  alias Mutare.Ecto.{AST, Ordering}

  @bound_macros ~w(limit offset)a

  @doc "Standalone/pipe clause-macro mutations for `node`, or `[]`."
  @spec mutations(Macro.t()) :: [Macro.t()]
  def mutations({:order_by, meta, args}) when is_list(args) and args != [] do
    {init, [ordering]} = Enum.split(args, -1)
    for flipped <- Ordering.flips(ordering), do: {:order_by, meta, init ++ [flipped]}
  end

  def mutations({macro, meta, args})
      when macro in @bound_macros and is_list(args) and args != [] do
    {init, [value]} = Enum.split(args, -1)

    case AST.int_value(value) do
      nil -> []
      n -> for bumped <- bumps(n), do: {macro, meta, init ++ [AST.int_literal(bumped)]}
    end
  end

  def mutations(_node), do: []

  # The off-by-one boundary, clamped non-negative (mirrors `Mutare.Ecto.Query`'s bound bumps).
  defp bumps(n) when n > 0, do: [n + 1, n - 1]
  defp bumps(n), do: [n + 1]
end
