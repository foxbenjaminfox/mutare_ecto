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
    |> Enum.map(&Sourceror.to_string/1)
    |> MapSet.new()
  end

  test "swaps a bare aggregate along its ladder" do
    assert swaps("sum(u.amount)") == MapSet.new(["avg(u.amount)"])
    assert swaps("avg(u.amount)") == MapSet.new(["sum(u.amount)"])
    assert swaps("min(u.x)") == MapSet.new(["max(u.x)"])
    assert swaps("max(u.x)") == MapSet.new(["min(u.x)"])
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
end
