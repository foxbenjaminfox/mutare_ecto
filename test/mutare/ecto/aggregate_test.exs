defmodule Mutare.Ecto.AggregateTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Aggregate

  # Unit tests for the select-expression aggregate walker — `Aggregate.swaps/1` over a parsed
  # select expression, rendered back. Delivery (whole-`from` vs standalone) is tested in
  # QueryTest/ClauseTest; here we pin which single-point swaps the walker offers across the
  # shapes a `select` can take.

  defp swaps(code) do
    code
    |> Sourceror.parse_string!()
    |> Aggregate.swaps()
    |> Enum.map(fn {:aggregate, node, _label} -> Sourceror.to_string(node) end)
    |> MapSet.new()
  end

  # The `{rendered_mutant, finer_label}` pairs, for asserting the source-function label.
  defp swap_labels(code) do
    code
    |> Sourceror.parse_string!()
    |> Aggregate.swaps()
    |> Enum.map(fn {:aggregate, node, label} -> {Sourceror.to_string(node), label} end)
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
    assert [{:aggregate, _node, _label}] = tagged
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
    # whose third slot is the atom hygiene context, not an args list. The `is_list(args)` guard on
    # the call clause is what stops the walker from trying to descend that atom (which would raise).
    assert swaps("u") == MapSet.new([])
  end
end
