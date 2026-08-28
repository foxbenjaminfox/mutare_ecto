defmodule Mutare.Ecto.ValueCatalog do
  @moduledoc false
  # The capability → shared-catalog dispatch for one clause **value** — a `select`/`select_merge`/
  # `order_by` value delivered **in place**: rebuilt into the whole `from` by `Mutare.Ecto.Query`
  # (and, under a value-wrapper, into a subquery's inner `from` by `Mutare.Ecto.Subquery`), or into
  # the standalone/pipe call by `Mutare.Ecto.Clause`. Every delivery reads the same
  # `Mutare.Ecto.Surface` capabilities off its clause key / macro name; this module is the one
  # place that says what each value capability *means*, and which position a value sits in, so the
  # deliveries can't drift from each other:
  #
  #   * `:ordering` — `Mutare.Ecto.Ordering.flips/1`: a direction/nulls flip of an ordering value.
  #   * `:aggregate` — `Mutare.Ecto.Aggregate.swaps/1`: a `sum`↔`avg`/`min`↔`max` swap.
  #   * `:scalar` — `Mutare.Ecto.Scalar.swaps/2`: an arithmetic swap or coalesce drop, aware of
  #     the value's position.
  #
  # `:combination` is deliberately not a value capability: it swaps the clause *key* / macro *name*
  # and keeps the value as written (`Mutare.Ecto.Combination`), so each delivery applies it in its
  # own shape. Neither is a `where`/`having` value (hosted — `Mutare.Ecto.Host.Catalog`) nor a
  # `limit`/`offset` bound (pin-only hosted — `Mutare.Ecto.Bound`).

  alias Mutare.Ecto.{Aggregate, ExpressionWalk, Ordering, Scalar, Surface, Tag}

  @typedoc "The capabilities that mutate a clause *value* (`Mutare.Ecto.Surface`'s, minus `:combination`)."
  @type capability :: :ordering | :aggregate | :scalar

  @doc """
  The position a value sits in, read off the capabilities its clause key / macro name carries:
  `:ordering` when the value *is* a sort key — the `:ordering` capability, i.e. an
  `order_by`/`prepend_order_by` value (where `Mutare.Ecto.Scalar`'s coalesce drop carries its
  own label/note); `:value` otherwise. Derived from the capability list rather than a hand-kept
  name list so it can't drift from `Surface`.
  """
  @spec position([Surface.from_capability()]) :: ExpressionWalk.position()
  def position(capabilities), do: if(:ordering in capabilities, do: :ordering, else: :value)

  @doc """
  The tagged mutants of one clause `value` under a value `capability`, at `position`
  (`position/1`), as self-tagging `Mutare.Ecto.Tag`s — the caller rebuilds its own surrounding
  form around each. Only `:scalar` reads the position; an ordering flip or aggregate swap means
  the same thing everywhere.
  """
  @spec mutants(capability(), Macro.t(), ExpressionWalk.position()) :: [Tag.t()]
  def mutants(:ordering, value, _position), do: Ordering.flips(value)
  def mutants(:aggregate, value, _position), do: Aggregate.swaps(value)
  def mutants(:scalar, value, position), do: Scalar.swaps(value, position)
end
