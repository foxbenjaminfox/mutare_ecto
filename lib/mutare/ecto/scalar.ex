defmodule Mutare.Ecto.Scalar do
  @moduledoc false
  # The shared **scalar-expression** catalog: mutations of value-computing operators that may
  # appear in *any* query expression, not only a boolean condition — the Arithmetic family
  # (`+`↔`-`, `*`↔`/`, paired by identity: 0 for the additive pair, 1 for the multiplicative).
  # Two consumers, mirroring `Mutare.Ecto.Aggregate`'s split:
  #
  #   * a hosted `where`/`having` condition — `Mutare.Ecto.Fragment` applies `local/1` per node
  #     as it walks the condition, so the swap is delivered `^`/`dynamic`-hosted alongside the
  #     operator swaps;
  #   * a `select`/`select_merge`/`order_by` value — `swaps/1` walks the whole expression
  #     (`Mutare.Ecto.ExpressionWalk`) and each swap is delivered **in place**
  #     (`Mutare.Ecto.Query` for the `from` keyword clauses, `Mutare.Ecto.Clause` for the
  #     standalone/pipe macros), exactly like the aggregate swap.
  #
  # SQL-owned for the same reason as the fragment catalog: NULL propagates through every arm
  # alike (a swap changes a row's computed value, never its NULL-ness), and `/` is the
  # *database's* division — integer truncation and a zero divisor raising are the engine's
  # behaviour, not Elixir's float `//2`. **Binary** forms only: a written negative number parses
  # as the arity-1 `-` over the wrapped literal — sign syntax, not an operator to swap.

  alias Mutare.Ecto.ExpressionWalk

  @arithmetic_swaps %{:+ => :-, :- => :+, :* => :/, :/ => :*}

  @doc """
  Every single-point scalar mutant of expression `expr` as `{family, node, label}` triples — the
  self-tagging contract the other shared catalogs (`Mutare.Ecto.Aggregate.swaps/1`,
  `Mutare.Ecto.Ordering.flips/1`) use. `label` is the **source** operator the swap mutates
  (`"+"` for `+`↔`-`), so `# mutare:ignore[ecto:+]` names just it.
  """
  @spec swaps(Macro.t()) :: [ExpressionWalk.tagged()]
  def swaps(expr), do: ExpressionWalk.walk(expr, &local/1)

  @doc """
  The scalar mutants of one node — **no descent** — the per-node hook `Mutare.Ecto.Fragment`
  applies as it walks a hosted condition (its own traversal already handles descent). The
  two-element args pattern is the binary-arity guard: a written `-5` is the arity-1 `-` over the
  wrapped literal, sign syntax with no swap (and Ecto has no unary `+`).
  """
  @spec local(Macro.t()) :: [ExpressionWalk.tagged()]
  def local({form, meta, [_l, _r] = args}) when is_map_key(@arithmetic_swaps, form),
    do: [{:arithmetic, {@arithmetic_swaps[form], meta, args}, to_string(form)}]

  def local(_node), do: []

  @doc false
  # The finer `# mutare:ignore` labels the scalar catalog can emit — each swappable operator,
  # derived from the swap table so the vocabulary can't drift from what's produced. Folded into
  # the plugin's variant vocabulary by `Mutare.Ecto.variants/0`.
  @spec variant_labels() :: [String.t()]
  def variant_labels, do: @arithmetic_swaps |> Map.keys() |> Enum.map(&to_string/1)
end
