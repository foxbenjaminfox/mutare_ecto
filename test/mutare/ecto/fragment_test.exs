defmodule Mutare.Ecto.FragmentTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Config, Fragment}

  @config Config.parse!([])

  # Unit tests for the SQL-semantics catalog itself — `Fragment.mutants/2` over a parsed
  # condition, rendered back to source. The host's *delivery* of these (the `^`/`dynamic`
  # weaving, routing) is `Mutare.Ecto.HostTest`'s job; here we pin exactly which single-point
  # variants the catalog offers for each family, reasoned in SQL's semantics (not Elixir's).

  # Every mutant of `code` as rendered source, as a set (order-independent). `opts` carries
  # `dialects:` (so a dialect-gated swap like `like`↔`ilike` can be exercised).
  defp mutants(code, opts \\ []) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants(Config.parse!(opts))
    |> Enum.map(&Sourceror.to_string(&1.node))
    |> MapSet.new()
  end

  # The families tagged on `code`'s mutants, as a set.
  defp families(code, opts \\ []) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants(Config.parse!(opts))
    |> Enum.map(& &1.family)
    |> MapSet.new()
  end

  # The finer `# mutare:ignore` label(s) tagged on each of `code`'s mutants, as a set (a label may
  # itself be a list when a deduped value collapses two kinds).
  defp labels(code, opts \\ []) do
    code
    |> Sourceror.parse_string!()
    |> Fragment.mutants(Config.parse!(opts))
    |> Enum.map(& &1.label)
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

    test "the is_nil argument is never descended — a value mutant there is provably equivalent" do
      # `is_nil(u.a + u.b)` is legal SQL, but an arithmetic (or literal) swap inside it can never
      # change the predicate: NULL propagates through every arm alike, so the mutant's NULL-ness —
      # the only thing `is_nil` observes — is exactly the original's. Only the polarity flips.
      assert mutants("is_nil(u.a + u.b)") == MapSet.new(["not is_nil(u.a + u.b)"])
      assert mutants("not is_nil(u.a + u.b)") == MapSet.new(["is_nil(u.a + u.b)"])
      assert mutants("is_nil(u.a + 5)") == MapSet.new(["not is_nil(u.a + 5)"])
    end

    test "the coalesce drop is the one mutant read beneath is_nil — it changes NULL-ness" do
      # `is_nil(coalesce(u.name, u.role))` asks about the *fallback chain*; dropping the fallback
      # asks about `u.name` alone, which differs on every row where `name` is NULL and `role` is
      # not. Both polarities offer it (rebuilt inside the written `not`), and nothing else
      # beneath the predicate does.
      assert mutants("is_nil(coalesce(u.name, u.role))") ==
               MapSet.new(["not is_nil(coalesce(u.name, u.role))", "is_nil(u.name)"])

      assert mutants("not is_nil(coalesce(u.name, u.role))") ==
               MapSet.new(["is_nil(coalesce(u.name, u.role))", "not is_nil(u.name)"])

      # A written default is data elsewhere, but not here: `coalesce(u.score, 1)` is non-NULL on
      # exactly the rows `coalesce(u.score, 0)` is, so no literal mutant rides along — only the
      # drop (the original is constantly false; the mutant is what says so).
      assert mutants("is_nil(coalesce(u.score, 0))") ==
               MapSet.new(["not is_nil(coalesce(u.score, 0))", "is_nil(u.score)"])
    end

    test "the drop is read at every depth of the is_nil argument, and only the drop" do
      # Nested fallbacks drop one layer per mutant, the default's own chain included…
      assert mutants("is_nil(coalesce(u.a, coalesce(u.b, u.c)))") ==
               MapSet.new([
                 "not is_nil(coalesce(u.a, coalesce(u.b, u.c)))",
                 "is_nil(u.a)",
                 "is_nil(coalesce(u.a, u.b))"
               ])

      # …and a coalesce under an arithmetic wrapper still drops (`is_nil(u.a + u.b)` differs
      # where `a` is NULL and `b` is not), while the `+` keeps its swap to itself and the written
      # `0` its literal mutants: NULL propagates through `+` and `-`, `0` and `1`, alike.
      assert mutants("is_nil(coalesce(u.a, 0) + u.b)") ==
               MapSet.new(["not is_nil(coalesce(u.a, 0) + u.b)", "is_nil(u.a + u.b)"])

      # A pinned default is a leaf for the narrowed walk as for the full one: the drop removes
      # the pin, and the pin's interior is never this catalog's (nor an island here — see the
      # island tests below).
      assert mutants("is_nil(coalesce(u.a, ^d))") ==
               MapSet.new(["not is_nil(coalesce(u.a, ^d))", "is_nil(u.a)"])
    end
  end

  describe "Membership" do
    test "in polarity flips both ways as a unit" do
      assert mutants("u.role in ^roles") == MapSet.new(["u.role not in ^roles"])
      assert mutants("u.role not in ^roles") == MapSet.new(["u.role in ^roles"])
    end

    test "the in predicate's operands are descended (one mutant per point)" do
      # Unlike `is_nil`, an operand mutant changes which rows match — so the left side's
      # arithmetic swap rides alongside the polarity flip, in both polarity directions (the
      # reverse rebuilds each descent mutant inside the written `not`, no double negation). The
      # renderer parenthesizes the rebuilt left operand; the precedence is the written one.
      assert mutants("u.a + u.b in ^list") ==
               MapSet.new(["(u.a + u.b) not in ^list", "(u.a - u.b) in ^list"])

      assert mutants("u.a + u.b not in ^list") ==
               MapSet.new(["(u.a + u.b) in ^list", "(u.a - u.b) not in ^list"])
    end

    test "a written in-list drops one element per mutant and mutates its literals" do
      # The element drops shrink the membership set one member at a time ("does any test pin this
      # member?"); each in-list literal also gets its ordinary value mutants — it is fragment SQL
      # exactly like a bare literal.
      assert mutants("u.x in [1, 2]") ==
               MapSet.new([
                 "u.x not in [1, 2]",
                 "u.x in [2]",
                 "u.x in [1]",
                 "u.x in [2, 2]",
                 "u.x in [0, 2]",
                 "u.x in [1, 3]",
                 "u.x in [1, 1]",
                 "u.x in [1, 0]"
               ])
    end

    test "a singleton written list still drops — to the constantly-false empty list" do
      assert mutants(~s|u.status in ["a"]|) ==
               MapSet.new([
                 ~s|u.status not in ["a"]|,
                 "u.status in []",
                 ~s|u.status in [""]|,
                 ~s|u.status in ["mutare"]|
               ])
    end

    test "a pinned or referenced right-hand side has no written elements to drop" do
      # Only a literal list the author wrote qualifies — a `^list` value is core's, and a column
      # reference (`"elixir" in p.tags`) has no member list in the source at all. A *written*
      # left-hand literal is still fragment data, so the array-membership form keeps its string
      # mutants while offering no drop.
      assert mutants("u.role in ^roles") == MapSet.new(["u.role not in ^roles"])

      assert mutants(~s|"elixir" in p.tags|) ==
               MapSet.new([
                 ~s|"elixir" not in p.tags|,
                 ~s|"" in p.tags|,
                 ~s|"mutare" in p.tags|
               ])
    end

    test "a non-list literal right-hand side has no elements to drop, never crashes" do
      # `element_drops/1`'s clause structurally matches any `x in <wrapped-literal>` — including a
      # right-hand side that *isn't* a list, an unusual shape but syntactically valid AST — and its
      # body assumes a list (`length/1`, `List.delete_at/2`). Without the `when is_list(elems)`
      # guard this raises `ArgumentError` instead of degrading to "no drops"; the polarity flip and
      # the literal's own value mutants still fire as usual.
      assert mutants(~s|u.x in "abc"|) ==
               MapSet.new([
                 ~s|u.x not in "abc"|,
                 ~s|u.x in ""|,
                 ~s|u.x in "mutare"|
               ])
    end

    test "exists polarity flips both ways as a unit" do
      # The subquery cousin of the `in` flip. The argument here is `subquery(sq)` — a *variable*
      # query, not an inline `from`, so there is no interior for `Mutare.Ecto.Subquery` to recurse
      # (it is mutated where `sq` is built); only the whole-predicate polarity flip fires, both ways,
      # with no double negation. (An inline `exists(from …)` additionally mutates its interior — see
      # the subquery-interior tests in `exotic_query_test.exs`.)
      assert mutants("exists(subquery(sq))") == MapSet.new(["not exists(subquery(sq))"])
      assert mutants("not exists(subquery(sq))") == MapSet.new(["exists(subquery(sq))"])
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

  describe "Arithmetic" do
    test "each binary arithmetic operator offers its identity-pair swap" do
      assert mutants("u.a + u.b") == MapSet.new(["u.a - u.b"])
      assert mutants("u.a - u.b") == MapSet.new(["u.a + u.b"])
      assert mutants("u.a * u.b") == MapSet.new(["u.a / u.b"])
      assert mutants("u.a / u.b") == MapSet.new(["u.a * u.b"])
    end

    test "an arithmetic operand under a comparison is reached (one mutant per point)" do
      # The comparison's swap and its right operand's arithmetic swap are separate single-point
      # mutants; the pinned `^v` stays core's.
      assert mutants("u.a + u.b > ^v") ==
               MapSet.new(["u.a - u.b > ^v", "u.a + u.b >= ^v"])
    end

    test "a literal operand of an arithmetic node still gets its own literal mutants" do
      assert mutants("u.total * 2 == ^v") ==
               MapSet.new([
                 "u.total / 2 == ^v",
                 "u.total * 2 != ^v",
                 "u.total * 3 == ^v",
                 "u.total * 1 == ^v",
                 "u.total * 0 == ^v"
               ])
    end

    test "a unary minus is sign syntax, not arithmetic — never swapped" do
      # A written negative number parses as the arity-1 `-` over the wrapped literal (Ecto has no
      # unary `+` to swap it to); only the comparison swaps and the *inner* literal mutates.
      assert mutants("u.x > -5") ==
               MapSet.new(["u.x >= -5", "u.x > -6", "u.x > -4", "u.x > -0"])
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
      assert families("u.a + u.b") == MapSet.new([:arithmetic])
      assert families("u.a / u.b") == MapSet.new([:arithmetic])
      assert families("is_nil(u.x)") == MapSet.new([:null_predicate])
      assert families("is_nil(coalesce(u.x, u.y))") == MapSet.new([:null_predicate, :coalesce])
      assert families("u.role in ^r") == MapSet.new([:membership])
      assert families("like(u.x, ^q)", dialects: [:postgres]) == MapSet.new([:membership])
    end

    test "the reverse-polarity unit clauses (not in / not is_nil / not exists) carry their family too" do
      # `not in`→`in`, `not is_nil`→`is_nil`, and `not exists`→`exists` are *separate* clauses
      # from their forward directions, so each one's tag is pinned in its own right — otherwise an
      # `atom` mutation of the family name on the reverse clause survives unnoticed.
      assert families("u.role not in ^r") == MapSet.new([:membership])
      assert families("not is_nil(u.x)") == MapSet.new([:null_predicate])

      assert families("not is_nil(coalesce(u.x, u.y))") ==
               MapSet.new([:null_predicate, :coalesce])

      assert families("exists(subquery(sq))") == MapSet.new([:membership])
      assert families("not exists(subquery(sq))") == MapSet.new([:membership])
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
        |> Fragment.mutants(@config)
        |> Enum.filter(&(&1.family == :integer_literal))
        |> Enum.map(&Sourceror.to_string(&1.node))
        |> Enum.sort()

      assert literals == ["u.age > 0", "u.age > 2"]
    end

    test "the deduped 0 carries both its kind labels (pred and zero)" do
      # `1`'s `n - 1` (pred) and its `0` sentinel (zero) collapse to one `0` mutant — tagged with
      # *both* kinds, so `# mutare:ignore[ecto:pred]` and `# mutare:ignore[ecto:zero]` each select it.
      labels =
        "u.age > 1"
        |> Sourceror.parse_string!()
        |> Fragment.mutants(@config)
        |> Enum.find(&(Sourceror.to_string(&1.node) == "u.age > 0"))
        |> Map.fetch!(:label)

      assert Enum.sort(labels) == ["pred", "zero"]
    end

    test "distinct-value literal mutants stay in candidate (succ, pred, zero) order" do
      # `value_mutants/3` documents itself as order-stable: each newly-seen value is appended, not
      # prepended, to the accumulator. `u.age > 1` sees `succ` (2) first, then `pred`/`zero` (both
      # 0, merging into one entry) — pin the *un-sorted* order so an accumulator that prepends
      # instead of appends (reversing which value comes first) is caught.
      ordered =
        "u.age > 1"
        |> Sourceror.parse_string!()
        |> Fragment.mutants(@config)
        |> Enum.filter(&(&1.family == :integer_literal))
        |> Enum.map(&Sourceror.to_string(&1.node))

      assert ordered == ["u.age > 2", "u.age > 0"]
    end

    test "a value's merged kind labels stay in first-seen order (pred before zero)" do
      # The same collision as above, but pinning the *label list's* internal order: `pred` (from
      # `n - 1`) is seen before `zero` (the sentinel), so the merged entry is `["pred", "zero"]`,
      # not `["zero", "pred"]` — catches a kind-merge that prepends instead of appending.
      labels =
        "u.age > 1"
        |> Sourceror.parse_string!()
        |> Fragment.mutants(@config)
        |> Enum.find(&(Sourceror.to_string(&1.node) == "u.age > 0"))
        |> Map.fetch!(:label)

      assert labels == ["pred", "zero"]
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

    test "the atom mutant is labelled sentinel" do
      assert labels("u.status == :active") == MapSet.new(["==", "sentinel"])
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

    test "the boolean flip is labelled negate" do
      assert labels("u.active == true") == MapSet.new(["==", "negate"])
    end
  end

  describe "Aggregate (folded in per node — one walk per condition)" do
    test "an aggregate swaps along its ladder inside a condition, beside the operator swaps" do
      assert mutants("sum(u.x) > 10") ==
               MapSet.new([
                 "avg(u.x) > 10",
                 "sum(u.x) >= 10",
                 "sum(u.x) > 11",
                 "sum(u.x) > 9",
                 "sum(u.x) > 0"
               ])

      assert families("min(u.x) == max(u.y)") == MapSet.new([:aggregate, :comparison])
      assert labels("min(u.x) == max(u.y)") == MapSet.new(["min", "max", "=="])
    end

    test "never under is_nil — a value aggregate is NULL exactly when it has no non-NULL input" do
      # `is_nil(sum(x))` ≡ `is_nil(avg(x))` on every engine (each is NULL iff the group has no
      # non-NULL value), so the swap would be unconditionally equivalent: the `is_nil` unit claims
      # its argument for the aggregate exactly as for the arithmetic and literal arms. (A second,
      # separate aggregate pass used to leak it.)
      assert mutants("is_nil(sum(u.x))") == MapSet.new(["not is_nil(sum(u.x))"])
      assert mutants("not is_nil(min(u.x))") == MapSet.new(["is_nil(min(u.x))"])
    end
  end

  describe "Temporal" do
    test "the interval helpers flip their time direction, unit intact" do
      # `ago`/`from_now` sit the same distance on opposite sides of now — the flip re-asks the
      # comparison against the mirror instant. The unit stays structural (no string mutants of
      # "day"); the count is ordinary data and keeps its literal mutants.
      assert mutants(~s|u.inserted_at > ago(3, "day")|) ==
               MapSet.new([
                 ~s|u.inserted_at >= ago(3, "day")|,
                 ~s|u.inserted_at > from_now(3, "day")|,
                 ~s|u.inserted_at > ago(4, "day")|,
                 ~s|u.inserted_at > ago(2, "day")|,
                 ~s|u.inserted_at > ago(0, "day")|
               ])
    end

    test "from_now flips back to ago" do
      assert ~s|u.due_at < ago(1, "week")| in mutants(~s|u.due_at < from_now(1, "week")|)
    end

    test "an off-arity same-named call is an author helper, left alone" do
      assert mutants("u.x > ago(3)") ==
               MapSet.new(["u.x >= ago(3)", "u.x > ago(4)", "u.x > ago(2)", "u.x > ago(0)"])
    end

    test "the flip labels by its source helper" do
      assert "ago" in labels(~s|u.t > ago(3, "day")|)
      assert "from_now" in labels(~s|u.t > from_now(3, "day")|)
    end
  end

  describe "Coalesce" do
    test "the NULL fallback drops inside a hosted condition, alongside the operator swaps" do
      # Pinned operands isolate the two structural mutants: the comparison swap and the
      # coalesce drop (the pins' values are core's, upstream).
      assert mutants("coalesce(u.score, ^d) > ^m") ==
               MapSet.new(["coalesce(u.score, ^d) >= ^m", "u.score > ^m"])
    end

    test "a written default is ordinary data — its literal mutants ride alongside the drop" do
      assert "coalesce(u.score, 1) > ^m" in mutants("coalesce(u.score, 0) > ^m")
      assert "u.score > ^m" in mutants("coalesce(u.score, 0) > ^m")
    end
  end

  describe "nothing to mutate" do
    test "a bare boolean column / non-catalog node yields no mutant" do
      assert mutants("u.active") == MapSet.new([])
      assert mutants("u.points") == MapSet.new([])
    end
  end

  describe "interpolation islands (`^expr`)" do
    # A pin's interior is ordinary Elixir evaluated at runtime — core's business, never this
    # catalog's. The catalog stops at the pin (no SQL-rationale `^(min * 2)` → `^(min / 2)`);
    # `islands/1` hands the interior to the host's core sub-contract instead.

    defp islands(code) do
      code
      |> Sourceror.parse_string!()
      |> Fragment.islands()
      |> Enum.map(fn {interior, rebuild} ->
        {Sourceror.to_string(interior), rebuild}
      end)
    end

    test "the catalog never offers or descends a pin's interior" do
      assert mutants("u.age > ^(min * 2)") == MapSet.new(["u.age >= ^(min * 2)"])
      assert mutants("u.age > ^100") == MapSet.new(["u.age >= ^100"])
    end

    test "islands/1 finds each pin and rebuilds the full condition around a replacement" do
      assert [{"min * 2", rebuild}] = islands("u.age > ^(min * 2)")

      assert rebuild.(Sourceror.parse_string!("min - 1")) |> Sourceror.to_string() ==
               "u.age > ^(min - 1)"
    end

    test "every pin in a compound condition is its own island, rebuilt single-point" do
      assert [{"a", rebuild_a}, {"b", rebuild_b}] = islands("u.x > ^a and u.y < ^b")

      assert rebuild_a.(Sourceror.parse_string!("z")) |> Sourceror.to_string() ==
               "u.x > ^z and u.y < ^b"

      assert rebuild_b.(Sourceror.parse_string!("z")) |> Sourceror.to_string() ==
               "u.x > ^a and u.y < ^z"
    end

    test "an island inside a written in-list is reached" do
      assert [{"base + 1", rebuild}] = islands("u.age in [18, ^(base + 1)]")

      assert rebuild.(Sourceror.parse_string!("base - 1")) |> Sourceror.to_string() ==
               "u.age in [18, ^(base - 1)]"
    end

    test "islands honor the catalog's no-descent predicates (is_nil) and a pinned subquery" do
      # `is_nil`: value mutants of a parameter preserve its NULL-ness — provably equivalent inside the
      # one predicate that observes only NULL-ness, so its argument is never entered. (The coalesce
      # drop the unit reads beneath itself — `is_nil(u.age)` — is the catalog's own mutant, not an
      # island: the pin is gone from it.)
      assert islands("is_nil(coalesce(u.age, ^default))") == []
      assert islands("not is_nil(coalesce(u.age, ^default))") == []

      # `exists(^sub)`: the argument is a pinned query built elsewhere (mutated where bound), not an
      # inline `from` — so there is no interior for `Mutare.Ecto.Subquery` to surface pins from.
      assert islands("exists(^sub)") == []
    end

    test "islands honor the author-macro rule — only :expression arguments are entered" do
      # An unregistered call (`nil` routing) is descended; the macro-routing overlay for a
      # `:skip`-routed author macro is exercised end to end in `macro_skip_test.exs`.
      assert [{"n", _rebuild}] = islands("clamp(u.age, ^n) > 10")
    end

    test "an island under a `not in` unit is rebuilt inside the written not" do
      # The polarity unit flips whole (`do_mutants/3`), but the island walk still descends its
      # operands — a pin among the written elements is core's exactly as in the positive form,
      # and the rebuild reconstructs the full negated predicate around the replacement.
      assert [{"b + 1", rebuild}] = islands("u.age not in [18, ^(b + 1)]")

      assert rebuild.(Sourceror.parse_string!("b - 1")) |> Sourceror.to_string() ==
               "u.age not in [18, ^(b - 1)]"
    end

    test "a pinned in-list right-hand side is itself an island" do
      # `x in ^list` has no written elements to drop, but the pin's interior is still ordinary
      # Elixir — the walk finds it exactly like an operand pin.
      assert [{"list", rebuild}] = islands("u.role in ^list")

      assert rebuild.(Sourceror.parse_string!("other")) |> Sourceror.to_string() ==
               "u.role in ^other"
    end

    test "islands are reached at the data positions of known Ecto DSL forms" do
      # The structural-position registry guards *literals* (a literal there is SQL shape, not
      # data) — a pin can only sit at a data position, and the island walk descends every
      # argument the author-macro rule allows, registry or not.
      assert [{"m * 2", rebuild}] = islands(~s|fragment("? > ?", u.age, ^(m * 2))|)

      assert rebuild.(Sourceror.parse_string!("m / 2")) |> Sourceror.to_string() ==
               ~s|fragment("? > ?", u.age, ^(m / 2))|

      assert [{"v + 1", _}] = islands("type(^(v + 1), :integer)")
      assert [{"n + 1", _}] = islands(~s|ago(^(n + 1), "month")|)
      assert [{"n + 1", _}] = islands(~s|datetime_add(u.inserted_at, ^(n + 1), "month")|)
    end

    test "a coalesce default is descended — the NULL-fallback pin is an island (unlike is_nil's)" do
      # The catalog descends coalesce's arguments (its own drop keeps the walk going), so the
      # island walk does too — the contrast with `is_nil`, whose argument is a hard boundary.
      assert [{"d * 2", rebuild}] = islands("coalesce(u.score, ^(d * 2)) > 10")

      assert rebuild.(Sourceror.parse_string!("d + 2")) |> Sourceror.to_string() ==
               "coalesce(u.score, ^(d + 2)) > 10"
    end

    test "deeply nested pins each rebuild single-point, and a no-descent branch stays empty" do
      # Two pins under different connective branches — each island's rebuild replaces exactly
      # its own pin; the `is_nil` branch between them contributes nothing.
      assert [{"x", rebuild_x}, {"y", rebuild_y}] =
               islands("(u.a > ^x or is_nil(u.b)) and u.c < ^y")

      assert rebuild_x.(Sourceror.parse_string!("z")) |> Sourceror.to_string() ==
               "(u.a > ^z or is_nil(u.b)) and u.c < ^y"

      assert rebuild_y.(Sourceror.parse_string!("z")) |> Sourceror.to_string() ==
               "(u.a > ^x or is_nil(u.b)) and u.c < ^z"
    end

    test "the pin is a boundary — everything beneath it is one interior, never walked further" do
      # A pin's interior goes to core *whole*: nothing inside it (not even a nested `^`, which
      # Ecto's grammar forbids anyway) becomes its own island.
      assert [{interior, _rebuild}] = islands("u.age > ^(f.(base + 1))")
      assert interior == "f.(base + 1)"
    end
  end

  describe "structural positions in known Ecto DSL forms" do
    # A literal at a *structural* position of a known Ecto DSL form shapes the SQL the builder
    # emits rather than carrying data — mutating it would produce a broken query, not a live
    # mutant — so the catalog skips it. Only the named positions are skipped; data literals at
    # *other* positions of the same form are still mutated, which is what makes these tests pin
    # the rule rather than just "fragment forms are inert".

    test "fragment's template (arg 0) is never mutated, but its data args still are" do
      # The `"? > ?"` template is structural (no ""/\"mutare\" variants); the `18` at arg 2 is
      # ordinary data and gets the integer boundary/sentinel mutants.
      assert mutants(~s|fragment("? > ?", u.age, 18)|) ==
               MapSet.new([
                 ~s|fragment("? > ?", u.age, 19)|,
                 ~s|fragment("? > ?", u.age, 17)|,
                 ~s|fragment("? > ?", u.age, 0)|
               ])
    end

    test "the same string type is skipped at the template but mutated at a data position" do
      # Position-specific: a string literal at arg 0 (template) is skipped, while a string at the
      # non-structural arg 2 still yields the empty-string / \"mutare\" sentinels.
      assert mutants(~s|fragment("? = ?", u.x, "ok")|) ==
               MapSet.new([
                 ~s|fragment("? = ?", u.x, "")|,
                 ~s|fragment("? = ?", u.x, "mutare")|
               ])
    end

    test "type/2's cast type (arg 1) is never mutated" do
      # A bare cast offers nothing (the atom is structural, the value is pinned)…
      assert mutants("type(^v, :integer)") == MapSet.new([])

      # …and nested under a comparison only the operator swaps — the `:integer` is not collapsed
      # to the `:mutare` sentinel the way an ordinary in-fragment atom would be.
      assert mutants("u.x == type(^v, :integer)") == MapSet.new(["u.x != type(^v, :integer)"])
    end

    test "datetime_add/date_add's interval unit (arg 2) is skipped; the count (arg 1) is not" do
      assert mutants(~s|datetime_add(u.inserted_at, 1, "month")|) ==
               MapSet.new([
                 ~s|datetime_add(u.inserted_at, 2, "month")|,
                 ~s|datetime_add(u.inserted_at, 0, "month")|
               ])

      assert mutants(~s|date_add(u.date, 1, "day")|) ==
               MapSet.new([
                 ~s|date_add(u.date, 2, "day")|,
                 ~s|date_add(u.date, 0, "day")|
               ])
    end

    test "from_now/ago's interval unit (arg 1) is skipped; the count (arg 0) is not" do
      # Alongside the temporal direction flip (the helper's own swap), only the *count* literal
      # mutates — never the unit string.
      assert mutants(~s|from_now(3, "month")|) ==
               MapSet.new([
                 ~s|ago(3, "month")|,
                 ~s|from_now(4, "month")|,
                 ~s|from_now(2, "month")|,
                 ~s|from_now(0, "month")|
               ])

      assert mutants(~s|ago(3, "day")|) ==
               MapSet.new([
                 ~s|from_now(3, "day")|,
                 ~s|ago(4, "day")|,
                 ~s|ago(2, "day")|,
                 ~s|ago(0, "day")|
               ])
    end

    test "the skip is keyed to the form — a same-named position elsewhere is unaffected" do
      # `type` is structural only at arg 1; an atom at arg 1 of a *non-registry* call is ordinary
      # data and still collapses to the sentinel, so the rule is a registry lookup, not a blanket
      # \"second argument is structural\".
      assert mutants("foo(u.x, :active)") == MapSet.new(["foo(u.x, :mutare)"])
    end

    test "field/2's column name (arg 1) is never mutated — only the surrounding condition" do
      # `field(u, :mutare)` is a wrong (usually nonexistent) column — a broken query, not a
      # live mutant. The comparison and its data literal keep their ordinary treatment.
      assert mutants("field(u, :views) > 10") ==
               MapSet.new([
                 "field(u, :views) >= 10",
                 "field(u, :views) > 11",
                 "field(u, :views) > 9",
                 "field(u, :views) > 0"
               ])
    end

    test "as/parent_as binding names (arg 0) are never mutated" do
      # A mutated binding name is an unknown-binding error at query build. Bare calls pin the
      # registry entries directly (in real source the calls are usually dot-accessed, whose
      # form the catalog never descends — the registry is the net for every other position).
      assert mutants("as(:posts)") == MapSet.new([])
      assert mutants("parent_as(:posts)") == MapSet.new([])
    end

    test "selected_as/1's alias name (arg 0) is never mutated — a having over an alias is safe" do
      # `selected_as(:mutare)` references an alias no select defined — an unknown-alias error,
      # not a mutant. The comparison around it keeps its full treatment.
      assert mutants("selected_as(:total) > 2") ==
               MapSet.new([
                 "selected_as(:total) >= 2",
                 "selected_as(:total) > 3",
                 "selected_as(:total) > 1",
                 "selected_as(:total) > 0"
               ])
    end

    test "a JSON bracket path index's boundary bumps land exactly on succ/pred/zero" do
      # Index `1` makes `pred` (0) and the `zero` sentinel collide (both 0) while `succ` (2) stays
      # distinct — isolating the family's own `int + 1` / `int - 1` / `0` literals, the `value >=
      # 0` filter, and the dedup-merge from the RHS string's unrelated family. Comparing against a
      # string RHS (not another integer) keeps the two literal families from overlapping.
      assert mutants(~s|u.meta["k"][1] == "z"|) ==
               MapSet.new([
                 ~s|u.meta["k"][1] != "z"|,
                 ~s|u.meta["k"][2] == "z"|,
                 ~s|u.meta["k"][0] == "z"|,
                 ~s|u.meta[""][1] == "z"|,
                 ~s|u.meta["mutare"][1] == "z"|,
                 ~s|u.meta["k"][1] == ""|,
                 ~s|u.meta["k"][1] == "mutare"|
               ])

      assert :integer_literal in families(~s|u.meta["k"][1] == "z"|)

      # The merged entry (index 0) carries both kind labels, first-seen order; the lone succ entry
      # (index 2) carries just its own.
      assert ["pred", "zero"] in labels(~s|u.meta["k"][1] == "z"|)
      assert ["succ"] in labels(~s|u.meta["k"][1] == "z"|)
    end

    test "a JSON bracket path index's boundary bumps stay distinct without a collision" do
      # Index `2`: succ/pred/zero (3, 1, 0) are all distinct and all non-negative, so every one of
      # the family's three internal literals (`+ 1`, `- 1`, the `0` sentinel), the filter's `0`
      # threshold, and the `>=` comparison itself each has to hold exactly for this set to survive
      # unchanged — any single off-by-one there collapses two entries together or drops one.
      assert mutants(~s|u.meta["k"][2] == "z"|) ==
               MapSet.new([
                 ~s|u.meta["k"][2] != "z"|,
                 ~s|u.meta["k"][3] == "z"|,
                 ~s|u.meta["k"][1] == "z"|,
                 ~s|u.meta["k"][0] == "z"|,
                 ~s|u.meta[""][2] == "z"|,
                 ~s|u.meta["mutare"][2] == "z"|,
                 ~s|u.meta["k"][2] == ""|,
                 ~s|u.meta["k"][2] == "mutare"|
               ])
    end

    test "selected_as/2's alias name (arg 1) is never mutated — the same rule as the /1 form" do
      # `selected_as(named_expr, :mutare)` references an alias no select defined — an unknown-alias
      # error, not a mutant. The expression and the surrounding comparison keep their full
      # treatment.
      assert mutants("selected_as(u.total, :grand_total) > 2") ==
               MapSet.new([
                 "selected_as(u.total, :grand_total) >= 2",
                 "selected_as(u.total, :grand_total) > 3",
                 "selected_as(u.total, :grand_total) > 1",
                 "selected_as(u.total, :grand_total) > 0"
               ])
    end

    test "a JSON bracket path mutates as data, except an index never goes negative" do
      # Path keys/indices select which JSON element the SQL reads — a different path differs
      # exactly on rows carrying the original one, so they are ordinary data. But Ecto's path
      # validator accepts only literal strings and integers, and a negative integer renders as
      # unary minus (`-(1)`), rejected at expansion — a poisoned build, so the `pred` bump of
      # `0` is suppressed while `succ` (and the string mutants) survive.
      assert mutants(~s|u.meta["k"][0] == 5|) ==
               MapSet.new([
                 ~s|u.meta["k"][0] != 5|,
                 ~s|u.meta[""][0] == 5|,
                 ~s|u.meta["mutare"][0] == 5|,
                 ~s|u.meta["k"][1] == 5|,
                 ~s|u.meta["k"][0] == 6|,
                 ~s|u.meta["k"][0] == 4|,
                 ~s|u.meta["k"][0] == 0|
               ])
    end

    test "json_extract_path's written path list follows the same rule as bracket access" do
      # The list's elements inherit the path-argument position, so an integer element keeps
      # only its non-negative mutants while string elements mutate as usual.
      assert mutants(~s|json_extract_path(u.meta, ["a", 0]) == "x"|) ==
               MapSet.new([
                 ~s|json_extract_path(u.meta, ["a", 0]) != "x"|,
                 ~s|json_extract_path(u.meta, ["", 0]) == "x"|,
                 ~s|json_extract_path(u.meta, ["mutare", 0]) == "x"|,
                 ~s|json_extract_path(u.meta, ["a", 1]) == "x"|,
                 ~s|json_extract_path(u.meta, ["a", 0]) == ""|,
                 ~s|json_extract_path(u.meta, ["a", 0]) == "mutare"|
               ])
    end
  end

  # The binding-reorder is no longer an in-fragment (catalog) mutation: it swaps a written binding
  # list in place — `Mutare.Ecto.BindingReorder` for the standalone/pipe macros (including
  # `where`/`having`), `Mutare.Ecto.Query` for a `from` source list — never the condition body. Its
  # tests live in `binding_reorder_test.exs`, not here.

  describe "finer `# mutare:ignore` labels" do
    test "a swap is tagged with the operator it mutates (the source operator)" do
      # `u.age < v` → `u.age <= v` is the mutation *of* `<`, so it's labelled `<` — that's what a
      # user writes to leave `<` alone (`# mutare:ignore[ecto:<]`), independent of `>`.
      assert labels("u.age < v") == MapSet.new(["<"])
      assert labels("u.age > v") == MapSet.new([">"])
      assert labels("u.x == u.y") == MapSet.new(["=="])
      assert labels("u.a and u.b") == MapSet.new(["and"])
      assert labels("u.a + u.b") == MapSet.new(["+"])
      assert labels("u.a * u.b") == MapSet.new(["*"])
    end

    test "the unit predicates label by their core operator (the wire-safe half)" do
      # `not is_nil`/`not in`/`not exists` carry a space, so both directions are labelled by the
      # bare operator.
      assert labels("is_nil(u.x)") == MapSet.new(["is_nil"])
      assert labels("not is_nil(u.x)") == MapSet.new(["is_nil"])
      assert labels("u.role in ^roles") == MapSet.new(["in"])
      assert labels("u.role not in ^roles") == MapSet.new(["in"])
      assert labels("exists(subquery(sq))") == MapSet.new(["exists"])
      assert labels("not exists(subquery(sq))") == MapSet.new(["exists"])
    end

    test "an in-list element drop is labelled element, apart from the polarity flip" do
      # A written list of pinned values has drops but no literal mutants, isolating the two
      # membership labels: `[ecto:element]` names the drops, `[ecto:in]` the polarity.
      assert labels("u.x in [^a, ^b]") == MapSet.new(["in", "element"])
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
          "u.f > 2.5",
          "u.a + u.b > u.c * u.d",
          "u.x in [1, 2]",
          "exists(subquery(sq))"
        ]
        |> Enum.flat_map(&MapSet.to_list(labels(&1)))
        |> List.flatten()
        |> MapSet.new()

      vocab = MapSet.new(Mutare.Ecto.variants(), &to_string/1)
      assert MapSet.subset?(emitted, vocab)
    end
  end
end
