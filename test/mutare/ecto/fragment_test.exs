defmodule Mutare.Ecto.FragmentTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Fragment

  # Unit tests for the SQL-semantics catalog itself — `Fragment.mutants/1` over a parsed
  # condition, rendered back to source. The host's *delivery* of these (the `^`/`dynamic`
  # weaving, routing) is `Mutare.Ecto.HostTest`'s job; here we pin exactly which single-point
  # variants the catalog offers for each family, reasoned in SQL's three-valued logic.

  # Every mutant of `code` as rendered source, as a set (order-independent). `opts` carries
  # `dialects:` (so a dialect-gated swap like `like`↔`ilike` can be exercised).
  defp mutants(code, opts \\ []) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants(opts)
    |> Enum.map(fn {_family, node, _label} -> Sourceror.to_string(node) end)
    |> MapSet.new()
  end

  # The families tagged on `code`'s mutants, as a set.
  defp families(code, opts \\ []) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants(opts)
    |> Enum.map(fn {family, _node, _label} -> family end)
    |> MapSet.new()
  end

  # The finer `# mutare:ignore` label(s) tagged on each of `code`'s mutants, as a set (a label may
  # itself be a list when a deduped value collapses two kinds).
  defp labels(code, opts \\ []) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants(opts)
    |> Enum.map(fn {_family, _node, label} -> label end)
    |> MapSet.new()
  end

  # Every binding-reorder mutant of `code` (given binding `names`) as a rendered set.
  defp reorders(code, names) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.binding_reorders(names)
    |> Enum.map(fn {:binding_reorder, node} -> Sourceror.to_string(node) end)
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

    test "like/ilike case-sensitivity swap is dialect-gated (Postgres)" do
      # Without a dialect, the ilike swap is not offered (the portable default).
      assert mutants("like(u.name, ^q)") == MapSet.new([])
      assert mutants("ilike(u.name, ^q)") == MapSet.new([])

      # Under :postgres, the swap fires both ways.
      assert mutants("like(u.name, ^q)", dialects: [:postgres]) ==
               MapSet.new(["ilike(u.name, ^q)"])

      assert mutants("ilike(u.name, ^q)", dialects: [:postgres]) ==
               MapSet.new(["like(u.name, ^q)"])
    end

    test "the swap is gated to postgres specifically — a different configured dialect won't enable it" do
      # `like`↔`ilike` is supported only under `:postgres`. Configuring some *other* dialect must
      # leave it gated off — i.e. the gate checks membership in the supported set, not merely "is
      # any dialect configured". (`[:postgres]` alone can't catch a `&1 in supported` → `true`
      # mutation, since postgres *is* in the supported set there.)
      assert mutants("like(u.name, ^q)", dialects: [:mysql]) == MapSet.new([])
      assert mutants("ilike(u.name, ^q)", dialects: [:mysql]) == MapSet.new([])
    end
  end

  describe "family tags" do
    test "each mutant is tagged with the SQL family that produced it" do
      assert families("u.age > 18") == MapSet.new([:comparison, :integer_literal])
      assert families("u.score > 2.5") == MapSet.new([:comparison, :float_literal])
      assert families(~s|u.name == "ok"|) == MapSet.new([:comparison, :string_literal])
      assert families("u.status == :active") == MapSet.new([:comparison, :atom_literal])
      assert families("u.active == true") == MapSet.new([:comparison, :boolean_literal])
      assert families("u.a and u.b") == MapSet.new([:connective])
      assert families("is_nil(u.x)") == MapSet.new([:null_predicate])
      assert families("u.role in ^r") == MapSet.new([:membership])
      assert families("like(u.x, ^q)", dialects: [:postgres]) == MapSet.new([:membership])
    end

    test "the reverse-polarity unit clauses (not in / not is_nil) carry their family too" do
      # `not in`→`in` and `not is_nil`→`is_nil` are *separate* clauses from their forward
      # directions, so each one's tag is pinned in its own right — otherwise an `atom` mutation
      # of the family name on the reverse clause survives unnoticed.
      assert families("u.role not in ^r") == MapSet.new([:membership])
      assert families("not is_nil(u.x)") == MapSet.new([:null_predicate])
    end
  end

  describe "IntegerLiteral" do
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

    test "colliding boundary variants are deduped — no repeated literal mutant" do
      # For `1`: n+1 = 2, n-1 = 0, and the zero sentinel is *also* 0, so the literal variants
      # are {2, 0}, not {2, 0, 0}. Asserted on the raw list (the `mutants/2` helper's MapSet
      # would mask the duplicate), so a dropped `Enum.uniq/1` — which re-emits `> 0` twice — is
      # caught.
      literals =
        "u.age > 1"
        |> Sourceror.parse_string!()
        |> Fragment.mutants()
        |> Enum.filter(fn {family, _node, _label} -> family == :integer_literal end)
        |> Enum.map(fn {_family, node, _label} -> Sourceror.to_string(node) end)
        |> Enum.sort()

      assert literals == ["u.age > 0", "u.age > 2"]
    end

    test "the deduped 0 carries both its kind labels (pred and zero)" do
      # `1`'s `n - 1` (pred) and its `0` sentinel (zero) collapse to one `0` mutant — tagged with
      # *both* kinds, so `# mutare:ignore[ecto:pred]` and `# mutare:ignore[ecto:zero]` each select it.
      labels =
        "u.age > 1"
        |> Sourceror.parse_string!()
        |> Fragment.mutants()
        |> Enum.find(fn {_family, node, _label} -> Sourceror.to_string(node) == "u.age > 0" end)
        |> elem(2)

      assert Enum.sort(labels) == ["pred", "zero"]
    end

    test "a pinned interpolation is left to core (no literal mutant)" do
      # `^min_age` is ordinary Elixir bound upstream — the catalog only swaps the operator.
      assert mutants("u.age > ^min_age") == MapSet.new(["u.age >= ^min_age"])
    end
  end

  describe "FloatLiteral" do
    test "an in-fragment float literal gets boundary ±1.0 and the 0.0 sentinel" do
      assert mutants("u.score > 2.5") ==
               MapSet.new(["u.score >= 2.5", "u.score > 3.5", "u.score > 1.5", "u.score > 0.0"])
    end

    test "n - 1.0 may go negative (a valid SQL value) and renders with a unary minus" do
      assert mutants("u.x > 0.5") ==
               MapSet.new(["u.x >= 0.5", "u.x > 1.5", "u.x > -0.5", "u.x > 0.0"])
    end

    test "colliding float variants dedupe against the 0.0 sentinel" do
      # `1.0`: n+1.0 = 2.0, n-1.0 = 0.0, sentinel 0.0 — so {2.0, 0.0}, not a repeated 0.0.
      assert mutants("u.price > 1.0") ==
               MapSet.new(["u.price >= 1.0", "u.price > 2.0", "u.price > 0.0"])
    end
  end

  describe "StringLiteral" do
    test "a plain string yields the empty string and the \"mutare\" sentinel" do
      assert mutants(~s|u.name == "ok"|) ==
               MapSet.new([~s|u.name != "ok"|, ~s|u.name == ""|, ~s|u.name == "mutare"|])
    end

    test "the sentinel value itself drops to just the empty string" do
      assert mutants(~s|u.name == "mutare"|) ==
               MapSet.new([~s|u.name != "mutare"|, ~s|u.name == ""|])
    end

    test "the empty string itself drops to just the sentinel" do
      assert mutants(~s|u.name == ""|) ==
               MapSet.new([~s|u.name != ""|, ~s|u.name == "mutare"|])
    end
  end

  describe "AtomLiteral" do
    test "a literal atom collapses to the :mutare sentinel" do
      assert mutants("u.status == :active") ==
               MapSet.new(["u.status != :active", "u.status == :mutare"])
    end

    test "the sentinel atom itself yields no atom mutant (only the operator swap)" do
      assert mutants("u.status == :mutare") == MapSet.new(["u.status != :mutare"])
    end

    test "true / false are BooleanLiteral's, not atoms; nil is left alone" do
      # The atom arm excludes them — booleans get the true↔false flip below, and `nil` (NULL/
      # absence) carries no atom mutant, only the operator swap.
      assert :atom_literal not in families("u.active == true")
      assert :atom_literal not in families("u.flag == false")
      assert mutants("u.x == nil") == MapSet.new(["u.x != nil"])
    end
  end

  describe "BooleanLiteral" do
    test "true and false flip to each other" do
      assert mutants("u.active == true") ==
               MapSet.new(["u.active != true", "u.active == false"])

      assert mutants("u.flag == false") ==
               MapSet.new(["u.flag != false", "u.flag == true"])
    end

    test "a boolean in a non-comparison position is flipped (descends into the fragment)" do
      # The point of the family: not the direct comparison, but a boolean used deeper in a
      # fragment — here the literal operand of an `and` flips while the connective swaps too.
      assert mutants("u.flag and true") ==
               MapSet.new(["u.flag or true", "u.flag and false"])
    end

    test "nil is not a boolean — it yields no boolean mutant" do
      assert :boolean_literal not in families("u.x == nil")
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

    test "each reorder is self-tagged with the :binding_reorder family" do
      tagged = "a.x == b.y" |> Sourceror.parse_string!() |> Fragment.binding_reorders([:a, :b])
      assert [{:binding_reorder, _node}] = tagged
    end
  end

  describe "finer `# mutare:ignore` labels" do
    test "a swap is tagged with the operator it mutates (the source operator)" do
      # `u.age < v` → `u.age <= v` is the mutation *of* `<`, so it's labelled `<` — that's what a
      # user writes to leave `<` alone (`# mutare:ignore[ecto:<]`), independent of `>`.
      assert labels("u.age < v") == MapSet.new(["<"])
      assert labels("u.age > v") == MapSet.new([">"])
      assert labels("u.x == u.y") == MapSet.new(["=="])
      assert labels("u.a and u.b") == MapSet.new(["and"])
    end

    test "the unit predicates label by their core operator (the wire-safe half)" do
      # `not is_nil`/`not in` carry a space, so both directions are labelled by the bare operator.
      assert labels("is_nil(u.x)") == MapSet.new(["is_nil"])
      assert labels("not is_nil(u.x)") == MapSet.new(["is_nil"])
      assert labels("u.role in ^roles") == MapSet.new(["in"])
      assert labels("u.role not in ^roles") == MapSet.new(["in"])
    end

    test "value families label by kind, not operator" do
      assert labels("u.age > 18") == MapSet.new([">", ["succ"], ["pred"], ["zero"]])
      assert labels(~s|u.name == "ok"|) == MapSet.new(["==", ["empty"], ["sentinel"]])
    end

    test "every emitted label is in the plugin's variant vocabulary (no drift)" do
      emitted =
        [
          "u.a and u.x == u.y",
          "is_nil(u.n)",
          "u.r in ^v",
          "u.age > 18",
          ~s|u.s == "x"|,
          "u.f > 2.5"
        ]
        |> Enum.flat_map(&MapSet.to_list(labels(&1)))
        |> List.flatten()
        |> MapSet.new()

      vocab = MapSet.new(Mutare.Ecto.variants(), &to_string/1)
      assert MapSet.subset?(emitted, vocab)
    end
  end
end
