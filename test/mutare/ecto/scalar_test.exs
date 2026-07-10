defmodule Mutare.Ecto.ScalarTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Scalar, Tag}

  # Unit tests for the shared scalar-expression catalog — `Scalar.swaps/1` over a parsed
  # expression, rendered back. Delivery (whole-`from` vs standalone vs hosted) is tested in
  # QueryTest/ClauseTest/FragmentTest; here we pin which single-point swaps the walker offers
  # across the shapes a `select`/`order_by` value can take.

  defp swaps(code) do
    code
    |> Sourceror.parse_string!()
    |> Scalar.swaps()
    |> Enum.map(&Sourceror.to_string(&1.node))
    |> MapSet.new()
  end

  # The `{rendered_mutant, finer_label}` pairs, for asserting the source-operator label.
  defp swap_labels(code) do
    code
    |> Sourceror.parse_string!()
    |> Scalar.swaps()
    |> Enum.map(&{Sourceror.to_string(&1.node), &1.label})
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
    assert [%Tag{family: :arithmetic}] = tagged
  end

  test "each swap carries the source operator as its finer label" do
    # `u.a + u.b` → `u.a - u.b` is the mutation *of* `+`, so it's labelled `+` — `[ecto:+]`
    # leaves `+` alone while the other operators keep mutating.
    assert swap_labels("u.a + u.b") == %{"u.a - u.b" => "+"}
    assert swap_labels("u.a * u.b") == %{"u.a / u.b" => "*"}
  end

  test "an interpolation island (`^expr`) is never offered or descended" do
    # The pin's interior is ordinary Elixir evaluated at runtime — outside the SQL catalog's
    # competence (an SQL-rationale `^(f + 1)` → `^(f - 1)` would mutate the *parameter*). Only
    # the genuinely-SQL outer operator swaps.
    assert swaps("u.votes * ^(f + 1)") == MapSet.new(["u.votes / ^(f + 1)"])
    assert swaps("^(f + 1)") == MapSet.new([])
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

  test "coalesce drops its NULL fallback, tagged with its own family" do
    assert swaps("coalesce(u.score, 0)") == MapSet.new(["u.score"])
    assert swap_labels("coalesce(u.score, 0)") == %{"u.score" => "coalesce"}

    tagged = "coalesce(u.score, 0)" |> Sourceror.parse_string!() |> Scalar.swaps()
    assert [%Tag{family: :coalesce, label: "coalesce"}] = tagged
  end

  test "a nested coalesce drops one layer per mutant, and its default is still descended" do
    # `coalesce(coalesce(u.a, u.b), 0)` — dropping the outer keeps the inner, dropping the inner
    # keeps the outer; each is a single point.
    assert swaps("coalesce(coalesce(u.a, u.b), 0)") ==
             MapSet.new(["coalesce(u.a, u.b)", "coalesce(u.a, 0)"])

    # A default that is itself arithmetic keeps its swap (the default is ordinary data).
    assert swaps("coalesce(u.score, u.a + u.b)") ==
             MapSet.new(["u.score", "coalesce(u.score, u.a - u.b)"])
  end

  test "an off-arity coalesce is not Ecto's and is left alone" do
    # Ecto's coalesce is exactly /2; a same-named author helper of another arity keeps only the
    # descent into its (standard-syntax) arguments.
    assert swaps("coalesce(u.a)") == MapSet.new([])
    assert swaps("coalesce(u.a, u.b, u.c)") == MapSet.new([])
  end

  test "a scalar-free select yields nothing" do
    assert swaps("u.id") == MapSet.new([])
    assert swaps("%{id: u.id}") == MapSet.new([])
    assert swaps("u") == MapSet.new([])
  end

  describe "ordering position (swaps/2)" do
    # A coalesce drop in a sort key has a different equivalence character — it re-sorts only the
    # NULL rows to the engine's *default* NULL placement, which may coincide with where the
    # fallback put them — so it carries its own finer label (the note/ignore discriminator).

    test "a coalesce drop in an ordering value carries the placement-aware label" do
      tagged =
        "[desc: coalesce(u.score, 0)]" |> Sourceror.parse_string!() |> Scalar.swaps(:ordering)

      assert [%Tag{family: :coalesce, label: "coalesce_in_ordering"}] = tagged
    end

    test "an arithmetic swap means the same thing in an ordering — label unchanged" do
      tagged = "[desc: u.a + u.b]" |> Sourceror.parse_string!() |> Scalar.swaps(:ordering)

      assert [%Tag{family: :arithmetic, label: "+"}] = tagged
    end

    test "an over/2 window's order_by: option is an ordering position inside a :value walk" do
      # The walk refines the position itself: a window's sort key is an ordering even when the
      # walk's root is an ordinary select value (the one place an ordering hides inside another
      # expression).
      code =
        "%{rank: over(row_number(), partition_by: u.hash, order_by: [desc: coalesce(u.ts, u.at)])}"

      tagged = code |> Sourceror.parse_string!() |> Scalar.swaps()

      assert [%Tag{family: :coalesce, label: "coalesce_in_ordering"}] = tagged
    end

    test "an over/2 window expression and partition_by: stay value positions" do
      # Only the sort key is an ordering: a coalesce under the window function or in the
      # partitioning keeps the plain label.
      code = "over(sum(coalesce(u.score, 0)), partition_by: coalesce(u.group, 0), order_by: u.id)"
      labels = code |> Sourceror.parse_string!() |> Scalar.swaps() |> Enum.map(& &1.label)

      assert labels == ["coalesce", "coalesce"]
    end
  end

  describe "node-level attribution" do
    # The walk stamps each mutant with `Mutation.at(node, mutant)` at the moment the catalog
    # offers it — so an in-place delivery reports the Site at the mutated expression's own range
    # (AttributionTest pins the delivered line/ignore behaviour; here the stamp itself).

    test "each walk mutant is stamped at the node it mutates" do
      [tag] = "%{total: sum(u.price * u.qty)}" |> Sourceror.parse_string!() |> Scalar.swaps()

      assert %Mutare.Mutator.Mutation.Attribution{} = tag.attribution
      assert Sourceror.to_string(tag.attribution.original) == "u.price * u.qty"
      assert Sourceror.to_string(tag.attribution.mutated) == "u.price / u.qty"
    end

    test "a coalesce drop's attribution shows the call collapsing to its wrapped expression" do
      [tag] = "%{at: coalesce(u.ts, u.at)}" |> Sourceror.parse_string!() |> Scalar.swaps()

      assert Sourceror.to_string(tag.attribution.original) == "coalesce(u.ts, u.at)"
      assert Sourceror.to_string(tag.attribution.mutated) == "u.ts"
    end
  end
end
