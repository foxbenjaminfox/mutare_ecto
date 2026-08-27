defmodule Mutare.Ecto.Bound do
  @moduledoc false
  # The `:bound` family's ±1 **bump** arm for a literal `limit`/`offset` value — the off-by-one
  # boundary of a paging bound. (The family's other arm, the bound *drop*, is a whole-`from`/stage
  # rewrite in `Mutare.Ecto.Query`/`Mutare.Ecto.ClauseDrop`.)
  #
  # A bump is delivered **hosted, pin-only**: the selector host weaves the tagged mutants as
  # `limit: ^(case …)` — no `dynamic/2` wrap, no bindings — because a bound is an integer
  # parameter, so the pinned selector is plain Ecto interpolation with a behaviorally identical
  # baseline (`Mutare.Ecto.Host` builds the target, `Mutare.Ecto.Host.Target.bound_from_clause/3`
  # and `bound_argument/3` the transforms). The routing classifier (`Mutare.Ecto.Host.Routing`)
  # marks the value `:hosted` through `literal?/1`, defined as `bumps/1` being non-empty, so
  # routing and host agree **by definition**: a value routes `:hosted` exactly when the host will
  # weave a bump for it, and there is no second encoding of "literal integer" to drift. A
  # `^pinned`/expression bound is left raw — its value is mutated where it is bound, in ordinary
  # Elixir.

  alias Mutare.Ecto.{AST, Tag}

  @doc """
  The tagged ±1 bumps for a bound value node (`limit:`/`offset:`): `n+1` always, and `n-1` only
  when it stays non-negative (a negative bound is invalid SQL). `[]` unless the value is a
  literal integer. Each bump is re-emitted through `Mutare.AST.literal/1` as a branch of the
  pin-only weave.
  """
  @spec bumps(Macro.t()) :: [Mutare.Mutator.mutation()]
  def bumps(value) do
    case AST.int_value(value) do
      nil ->
        []

      n ->
        for bumped <- off_by_one(n),
            do: Tag.to_mutation(Tag.new(:bound, Mutare.AST.literal(bumped)))
    end
  end

  @doc """
  The literal-only bound guard: whether `bumps/1` produces any bump for this value. `off_by_one/1`
  always yields at least `n + 1`, so non-emptiness is precisely literal-integer-ness — the routing
  classifier routes a bound `:hosted` through this predicate.
  """
  @spec literal?(Macro.t()) :: boolean()
  def literal?(value), do: bumps(value) != []

  defp off_by_one(n) when n > 0, do: [n + 1, n - 1]
  defp off_by_one(n), do: [n + 1]
end
