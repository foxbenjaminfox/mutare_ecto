defmodule Mutare.Ecto.OrderingTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Ordering

  # Unit tests for the shared ordering-flip catalog — `Ordering.flips/1` over a parsed `order_by`
  # value, rendered back as `{family, source}`. Delivery (whole-`from` via QueryTest, standalone via
  # ClauseTest) is tested there; here we pin which single-axis flips it offers and which list shapes
  # it accepts.

  defp flips(code) do
    code
    |> Sourceror.parse_string!()
    |> Ordering.flips()
    |> Enum.map(fn {family, node} -> {family, Sourceror.to_string(node)} end)
  end

  test "a bare direction flips only its direction (no nulls placement declared)" do
    assert flips("[asc: u.name]") == [{:ordering, "[desc: u.name]"}]
    assert flips("[desc: u.name]") == [{:ordering, "[asc: u.name]"}]
  end

  test "a bare field (implicit ascending) is not a flippable axis and doesn't crash the walk" do
    # `order_by: [p.id, asc: p.name]` — the bare `p.id` carries no direction key, so axis_flips
    # falls through to []; only the keyed `asc: p.name` flips. (Without that fallback the walk would
    # raise on the bare field rather than skip it.)
    assert flips("[p.id, asc: p.name]") == [{:ordering, "[p.id, desc: p.name]"}]
  end

  test "a non-list ordering value yields nothing" do
    assert flips("u.name") == []
  end
end
