defmodule Mutare.Ecto.ScalarTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Scalar

  # Unit tests for the shared scalar-expression catalog — `Scalar.swaps/1` over a parsed
  # expression, rendered back. Delivery (whole-`from` vs standalone vs hosted) is tested in
  # QueryTest/ClauseTest/FragmentTest; here we pin which single-point swaps the walker offers
  # across the shapes a `select`/`order_by` value can take.

  defp swaps(code) do
    code
    |> Sourceror.parse_string!()
    |> Scalar.swaps()
    |> Enum.map(fn {:arithmetic, node, _label} -> Sourceror.to_string(node) end)
    |> MapSet.new()
  end

  # The `{rendered_mutant, finer_label}` pairs, for asserting the source-operator label.
  defp swap_labels(code) do
    code
    |> Sourceror.parse_string!()
    |> Scalar.swaps()
    |> Enum.map(fn {:arithmetic, node, label} -> {Sourceror.to_string(node), label} end)
    |> Map.new()
  end

  test "swaps each binary operator along its identity pair" do
    assert swaps("u.a + u.b") == MapSet.new(["u.a - u.b"])
    assert swaps("u.a - u.b") == MapSet.new(["u.a + u.b"])
    assert swaps("u.a * u.b") == MapSet.new(["u.a / u.b"])
    assert swaps("u.a / u.b") == MapSet.new(["u.a * u.b"])
  end

  test "each swap is self-tagged with the :arithmetic family" do
    tagged = "u.a + u.b" |> Sourceror.parse_string!() |> Scalar.swaps()
    assert [{:arithmetic, _node, _label}] = tagged
  end

  test "each swap carries the source operator as its finer label" do
    # `u.a + u.b` → `u.a - u.b` is the mutation *of* `+`, so it's labelled `+` — `[ecto:+]`
    # leaves `+` alone while the other operators keep mutating.
    assert swap_labels("u.a + u.b") == %{"u.a - u.b" => "+"}
    assert swap_labels("u.a * u.b") == %{"u.a / u.b" => "*"}
  end

  test "a unary minus is sign syntax, never swapped" do
    # A written negative number is the arity-1 `-` over the wrapped literal — no `+5` mutant.
    assert swaps("-5") == MapSet.new([])
    assert swaps("u.a > -5") == MapSet.new([])
  end

  test "reaches operators inside a map and a keyword list, one single-point mutant each" do
    assert swaps("%{total: u.price * u.qty, net: u.gross - u.tax}") ==
             MapSet.new([
               "%{total: u.price / u.qty, net: u.gross - u.tax}",
               "%{total: u.price * u.qty, net: u.gross + u.tax}"
             ])

    assert swaps("[desc: u.a + u.b]") == MapSet.new(["[desc: u.a - u.b]"])
  end

  test "reaches an operator nested under an aggregate call" do
    # `sum(u.price * u.qty)` — the aggregate is Aggregate's; the operator inside is this
    # catalog's, reached by descending the (non-macro-routed) call's argument.
    assert swaps("sum(u.price * u.qty)") == MapSet.new(["sum(u.price / u.qty)"])
  end

  test "a tuple select descends into both sides" do
    assert swaps("{u.id, u.a + u.b}") == MapSet.new(["{u.id, u.a - u.b}"])
  end

  test "a scalar-free select yields nothing" do
    assert swaps("u.id") == MapSet.new([])
    assert swaps("%{id: u.id}") == MapSet.new([])
    assert swaps("u") == MapSet.new([])
  end
end
