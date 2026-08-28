defmodule Mutare.Ecto.AggregateTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Aggregate, Tag}

  # Unit tests for the select-expression aggregate walker — `Aggregate.swaps/1` over a parsed
  # select expression, rendered back. Delivery (whole-`from` vs standalone) is tested in
  # QueryTest/ClauseTest; here we pin which single-point swaps the walker offers across the
  # shapes a `select` can take.

  defp swaps(code) do
    code
    |> Sourceror.parse_string!()
    |> Aggregate.swaps()
    |> Enum.map(fn %Tag{family: :aggregate, node: node} -> Sourceror.to_string(node) end)
    |> MapSet.new()
  end

  # The `{rendered_mutant, finer_label}` pairs, for asserting the source-function label.
  defp swap_labels(code) do
    code
    |> Sourceror.parse_string!()
    |> Aggregate.swaps()
    |> Enum.map(fn %Tag{family: :aggregate, node: node, label: label} ->
      {Sourceror.to_string(node), label}
    end)
    |> Map.new()
  end

  test "swaps a bare aggregate along its ladder" do
    assert swaps("sum(u.amount)") == MapSet.new(["avg(u.amount)"])
    assert swaps("avg(u.amount)") == MapSet.new(["sum(u.amount)"])
    assert swaps("min(u.x)") == MapSet.new(["max(u.x)"])
    assert swaps("max(u.x)") == MapSet.new(["min(u.x)"])
  end

  test "each swap is self-tagged with the :aggregate family" do
    tagged = "sum(u.amount)" |> Sourceror.parse_string!() |> Aggregate.swaps()
    assert [%Tag{family: :aggregate}] = tagged
  end

  test "each swap carries the source function as its finer label" do
    # `sum(u.x)` → `avg(u.x)` is the mutation *of* sum, so it's labelled `sum` — `[ecto:sum]` leaves
    # sum alone while `avg`/`min`/`max` keep mutating.
    assert swap_labels("sum(u.amount)") == %{"avg(u.amount)" => "sum"}
    assert swap_labels("avg(u.amount)") == %{"sum(u.amount)" => "avg"}
    assert swap_labels("min(u.x)") == %{"max(u.x)" => "min"}
    assert swap_labels("max(u.x)") == %{"min(u.x)" => "max"}
  end

  test "count is left alone (arity/meaning contract)" do
    assert swaps("count(u.id)") == MapSet.new([])
  end

  test "an off-arity call wearing an aggregate name is left alone" do
    # Every rung of the ladder is `/1`, so a `sum/2` is not Ecto's `sum` — it is an author macro
    # (or `Kernel.min/2`) that merely shares the atom. Renaming it emits `avg(a, b)`, which no
    # module defines: Ecto's builder rejects it at expansion and the *whole* metamutant build
    # fails. `Mutare.Ecto.Aggregate.local/2`, `Mutare.Ecto.Scalar.local/2` for the sibling guard.
    assert swaps("sum(u.x, u.y)") == MapSet.new([])
    assert swaps("max(u.x, u.y)") == MapSet.new([])
    assert swaps("sum()") == MapSet.new([])
  end

  test "reaches aggregates inside a map, one single-point mutant each" do
    assert swaps("%{total: sum(u.amount), peak: max(u.x)}") ==
             MapSet.new([
               "%{total: avg(u.amount), peak: max(u.x)}",
               "%{total: sum(u.amount), peak: min(u.x)}"
             ])
  end

  test "reaches aggregates inside a tuple and a keyword list" do
    assert swaps("{sum(u.x), avg(u.y)}") ==
             MapSet.new(["{avg(u.x), avg(u.y)}", "{sum(u.x), sum(u.y)}"])

    assert swaps("[total: sum(u.x)]") == MapSet.new(["[total: avg(u.x)]"])
  end

  test "a non-aggregate select yields nothing" do
    assert swaps("u.id") == MapSet.new([])
    assert swaps("%{id: u.id, name: u.name}") == MapSet.new([])
  end

  test "a bare binding variable (whole-struct select) yields nothing, never a crash" do
    # `select(q, [u], u)` selects the whole struct: the value `u` is a variable node `{:u, _, ctx}`
    # whose third slot is the atom hygiene context, not an args list. The single-argument list
    # pattern on the call clause is what stops the walker from treating that atom as arguments
    # (which would raise) — including for a variable that happens to be *named* after a rung.
    assert swaps("u") == MapSet.new([])
    assert swaps("sum") == MapSet.new([])
  end
end
