defmodule Mutare.Ecto.Scalar do
  @moduledoc false
  # The shared **scalar-expression** catalog: mutations of value-computing forms that may
  # appear in *any* query expression, not only a boolean condition —
  #
  #   * **Arithmetic** — `+`↔`-`, `*`↔`/`, paired by identity: 0 for the additive pair, 1 for
  #     the multiplicative;
  #   * **Coalesce** — `coalesce(x, default)` → `x`, dropping the NULL fallback ("does any test
  #     exercise the row where the default kicks in?"). The one catalog mutation that *changes*
  #     an expression's NULL-ness — that is its entire point: the two forms differ exactly on the
  #     rows where `x` is NULL, so its survivors carry a NULL-data equivalence note.
  #
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

  alias Mutare.Ecto.{ExpressionWalk, Tag}

  @behaviour Mutare.Ecto.Vocabulary

  @arithmetic_swaps %{:+ => :-, :- => :+, :* => :/, :/ => :*}

  # The ordering-position coalesce drop's finer label. Named apart from the plain "coalesce"
  # because its equivalence character differs: dropping the fallback in a sort key re-sorts only
  # the NULL rows to the engine's *default* NULL placement — which may coincide with where the
  # fallback put them (Postgres sorts NULL as larger than every value, SQLite/MySQL as smaller;
  # see `Mutare.Ecto.Ordering`). The distinct label lets `Mutare.Ecto.Equivalence.note/2`
  # attach the placement-aware note, and lets `# mutare:ignore[ecto:coalesce_in_ordering]` name
  # exactly the ordering-position drop — while a family-level `[ecto:coalesce]` still covers both.
  @ordering_coalesce_label "coalesce_in_ordering"

  @doc """
  Every single-point scalar mutant of expression `expr` as self-tagging `Mutare.Ecto.Tag`s — the
  contract the other shared catalogs (`Mutare.Ecto.Aggregate.swaps/1`,
  `Mutare.Ecto.Ordering.flips/1`) use. The label is the **source** operator the swap mutates
  (`"+"` for `+`↔`-`), so `# mutare:ignore[ecto:+]` names just it. `position` is the expression's
  root position (`:ordering` for an `order_by` value — `Mutare.Ecto.ExpressionWalk.position/0`);
  a coalesce drop there is labelled `"coalesce_in_ordering"`.
  """
  @spec swaps(Macro.t(), ExpressionWalk.position()) :: [Tag.t()]
  def swaps(expr, position \\ :value), do: ExpressionWalk.walk(expr, &local/2, position)

  @doc """
  The scalar mutants of one node — **no descent** — the per-node hook `Mutare.Ecto.Fragment`
  applies as it walks a hosted condition (its own traversal already handles descent; a boolean
  condition is a `:value` position by construction). The two-element args pattern is the
  binary-arity guard: a written `-5` is the arity-1 `-` over the wrapped literal, sign syntax
  with no swap (and Ecto has no unary `+`); `coalesce` is exactly `/2` in Ecto, so an off-arity
  call is left alone.
  """
  @spec local(Macro.t()) :: [Tag.t()]
  def local(node), do: local(node, :value)

  @doc false
  # The position-aware per-node catalog `swaps/2` threads through the walk. Only the coalesce
  # drop reads the position (its label); an arithmetic swap means the same thing everywhere.
  @spec local(Macro.t(), ExpressionWalk.position()) :: [Tag.t()]
  def local({form, meta, [_l, _r] = args}, _position) when is_map_key(@arithmetic_swaps, form),
    do: [Tag.new(:arithmetic, {@arithmetic_swaps[form], meta, args}, to_string(form))]

  # The coalesce drop replaces the whole call with its wrapped expression — a same-type,
  # compile-safe alternative whose only difference is where NULL rows land. The *default*'s own
  # value mutants are the traversal's job (it is an ordinary data argument).
  def local({:coalesce, _meta, [x, _default]}, position),
    do: [Tag.new(:coalesce, x, coalesce_label(position))]

  def local(_node, _position), do: []

  # `Mutare.Ecto.Vocabulary`: each swappable operator plus the coalesce drop's two positional
  # labels.
  @impl Mutare.Ecto.Vocabulary
  def variant_labels do
    operators = @arithmetic_swaps |> Map.keys() |> Enum.map(&to_string/1)
    operators ++ [coalesce_label(:value), coalesce_label(:ordering)]
  end

  defp coalesce_label(:ordering), do: @ordering_coalesce_label
  defp coalesce_label(:value), do: "coalesce"
end
