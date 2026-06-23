defmodule Mutare.Ecto.FragmentTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Fragment

  # Unit tests for the SQL-semantics catalog itself — `Fragment.mutants/1` over a parsed
  # condition, rendered back to source. The host's *delivery* of these (the `^`/`dynamic`
  # weaving, routing) is `Mutare.Ecto.HostTest`'s job; here we pin exactly which single-point
  # variants the catalog offers for each family, reasoned in SQL's three-valued logic.

  # Every mutant of `code` as rendered source, as a set (order-independent).
  defp mutants(code) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants()
    |> Enum.map(&Sourceror.to_string/1)
    |> MapSet.new()
  end

  # Every binding-reorder mutant of `code` (given binding `names`) as a rendered set.
  defp reorders(code, names) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.binding_reorders(names)
    |> Enum.map(&Sourceror.to_string/1)
    |> MapSet.new()
  end

  describe "Comparison" do
    test "each comparison offers its single boundary/equality swap" do
      assert mutants("u.age > v") == MapSet.new(["u.age >= v"])
      assert mutants("u.age >= v") == MapSet.new(["u.age > v"])
      assert mutants("u.age < v") == MapSet.new(["u.age <= v"])
      assert mutants("u.age <= v") == MapSet.new(["u.age < v"])
      assert mutants("u.x == u.y") == MapSet.new(["u.x != u.y"])
      assert mutants("u.x != u.y") == MapSet.new(["u.x == u.y"])
    end
  end

  describe "Connective" do
    test "and/or swap, and it descends into both operands" do
      assert mutants("u.a and u.b") == MapSet.new(["u.a or u.b"])
      assert mutants("u.a or u.b") == MapSet.new(["u.a and u.b"])

      # The connective swap plus each operand's own swap — one mutant per single point.
      assert mutants("u.x == u.y and u.z < u.w") ==
               MapSet.new([
                 "u.x == u.y or u.z < u.w",
                 "u.x != u.y and u.z < u.w",
                 "u.x == u.y and u.z <= u.w"
               ])
    end
  end

  describe "NullPredicate" do
    test "is_nil flips both ways as one unit (no double negation)" do
      assert mutants("is_nil(u.name)") == MapSet.new(["not is_nil(u.name)"])
      assert mutants("not is_nil(u.name)") == MapSet.new(["is_nil(u.name)"])
    end
  end

  describe "Membership" do
    test "in polarity flips both ways as a unit" do
      assert mutants("u.role in ^roles") == MapSet.new(["u.role not in ^roles"])
      assert mutants("u.role not in ^roles") == MapSet.new(["u.role in ^roles"])
    end

    test "like/ilike case-sensitivity swap" do
      assert mutants("like(u.name, ^q)") == MapSet.new(["ilike(u.name, ^q)"])
      assert mutants("ilike(u.name, ^q)") == MapSet.new(["like(u.name, ^q)"])
    end
  end

  describe "FragmentLiteral" do
    test "an in-fragment integer literal gets boundary ±1 and the zero sentinel" do
      # `u.age >= 18` offers the comparison swap *and* three literal variants for `18`.
      assert mutants("u.age >= 18") ==
               MapSet.new(["u.age > 18", "u.age >= 19", "u.age >= 17", "u.age >= 0"])
    end

    test "a literal already at a boundary dedupes and clamps non-negative" do
      # `0` never re-emits `0`, and `n - 1` (= -1) is a valid SQL value (kept), so `> 0`
      # yields the comparison swap plus `> 1` and `> -1`.
      assert mutants("u.x > 0") == MapSet.new(["u.x >= 0", "u.x > 1", "u.x > -1"])
    end

    test "a pinned interpolation is left to core (no literal mutant)" do
      # `^min_age` is ordinary Elixir bound upstream — the catalog only swaps the operator.
      assert mutants("u.age > ^min_age") == MapSet.new(["u.age >= ^min_age"])
    end

    test "a string literal in the fragment is not mutated" do
      # Only integers are SQL-boundary mutated; the `==` swap is the lone variant.
      assert mutants(~s|u.name == "ok"|) == MapSet.new([~s|u.name != "ok"|])
    end
  end

  describe "nothing to mutate" do
    test "a bare boolean column / non-catalog node yields no mutant" do
      assert mutants("u.active") == MapSet.new([])
      assert mutants("u.points") == MapSet.new([])
    end
  end

  describe "binding_reorders/2" do
    test "swaps two binding references that both appear" do
      assert reorders("a.x == b.y", [:a, :b]) == MapSet.new(["b.x == a.y"])
    end

    test "needs both bindings present — a single-reference condition yields nothing" do
      assert reorders("a.x == a.y", [:a, :b]) == MapSet.new([])
      assert reorders("a.x > ^v", [:a, :b]) == MapSet.new([])
    end

    test "one mutant per pair for three bindings" do
      assert reorders("a.x == b.y and b.z < c.w", [:a, :b, :c]) ==
               MapSet.new([
                 "b.x == a.y and a.z < c.w",
                 "c.x == b.y and b.z < a.w",
                 "a.x == c.y and c.z < b.w"
               ])
    end

    test "a single-binding query has nothing to reorder" do
      assert reorders("a.x == a.y", [:a]) == MapSet.new([])
    end
  end
end
