defmodule Mutare.Ecto.QueryTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "drops each where clause (binding form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from(p in "posts", where: p.active, where: not p.deleted, select: p.id)
    end
    """

    # Two where clauses → exactly two whole-`from` drop mutants, each removing one where and
    # keeping the select and the surviving where. Pinned as exact origin→target pairs so a
    # wrong-clause drop, a missing drop, or an over-mutation can't slip past.
    assert ecto_diffs(src) == [
             {~s|from(p in "posts", where: p.active, where: not p.deleted, select: p.id)|,
              ~s|from(p in "posts", where: not p.deleted, select: p.id)|},
             {~s|from(p in "posts", where: p.active, where: not p.deleted, select: p.id)|,
              ~s|from(p in "posts", where: p.active, select: p.id)|}
           ]
  end

  test "drops a where clause (bindingless keyword form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from("posts", where: [active: true], select: [:id])
    end
    """

    # The lone where drops (whole-`from`), keeping the select — the exact and only mutant.
    assert ecto_diffs(src) == [
             {~s|from("posts", where: [active: true], select: [:id])|,
              ~s|from("posts", select: [:id])|}
           ]
  end

  test "flips an order_by direction" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from(p in "posts", order_by: [asc: p.name])
    end
    """

    # A bare direction declares no NULLs placement, so it yields only the direction flip.
    assert [{_o, mutated}] = ecto_diffs(src)
    assert mutated =~ "desc: p.name"
  end

  test "a nulls-qualified ordering splits into independent direction and placement axes" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from(p in "posts", order_by: [asc_nulls_first: p.name])
    end
    """

    only = fn families ->
      src
      |> ecto_diffs(mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: families}])
      |> Enum.map(fn {_o, mutated} -> mutated end)
    end

    # :ordering — flip the direction, keep the NULLs placement.
    assert [direction] = only.([:ordering])
    assert direction =~ "desc_nulls_first: p.name"

    # :ordering_nulls — flip the NULLs placement, keep the direction.
    assert [nulls] = only.([:ordering_nulls])
    assert nulls =~ "asc_nulls_last: p.name"

    # Both axes together: two mutants, each flipping exactly one component (never both at once,
    # which the old single combined flip did — a weaker mutant any order-pinning test killed).
    assert length(only.([:ordering, :ordering_nulls])) == 2
  end

  test "does not treat a module-qualified order helper call as an implicit field ordering" do
    src = """
    defmodule Posts.OrderHelpers do
      defmacro runtime_order(_field) do
        quote do
          ^[asc: :name]
        end
      end
    end

    defmodule Posts do
      import Ecto.Query
      require Posts.OrderHelpers

      def q(field), do: from(p in "posts", order_by: Posts.OrderHelpers.runtime_order(field))
    end
    """

    assert ecto_diffs(src) == []
    assert_compiles(src)
  end

  test "does not fire on a plain (non-from) call" do
    src = """
    defmodule M do
      def q(x), do: from_cache(x)
    end
    """

    assert ecto_diffs(src) == []
  end

  describe "Bound (limit/offset)" do
    test "drops a limit clause and bumps its value by ±1 (the bump woven pin-only)" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", limit: 10, select: p.id)
      end
      """

      diffs = ecto_diffs(src)

      # The whole-`from` drop removes the limit (the surviving query keeps select)…
      assert Enum.any?(diffs, fn {_o, mutated} ->
               mutated =~ "from" and not (mutated =~ "limit")
             end)

      # …while the literal bound bumps are hosted: the recorded diff is the logical pair alone,
      # with the literal's own range — never a rewritten copy of the whole query.
      assert {"10", "11"} in diffs
      assert {"10", "9"} in diffs

      # Delivery shape: the bump is woven pin-only into the bound position
      # (`limit: ^case mutare_active do … end`)…
      mm = metamutant(src)
      assert mm =~ ~r/limit:\s*\^case/
      # …with no `dynamic/2` wrap — the branches are bare integers, plain Ecto interpolation
      # (a `^dynamic` in a limit position would be broken Ecto)…
      refute mm =~ "dynamic"
      # …so the query is not duplicated per bump: `from(` appears exactly twice — the baseline
      # and the (whole-`from`) drop mutant. The bumps used to add two more full copies.
      assert length(String.split(mm, "from(")) - 1 == 2

      assert_compiles(src)
    end

    test "a disabled :bound family leaves the bound position raw — no orphan scaffolding" do
      # `finalize/2` skips every mutant of a disabled family, and core drops a host target whose
      # mutants all skip — so the weave itself must vanish, not just the recorded sites. The
      # sibling condition still weaves: the family gate is per-target, never per-call.
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", where: p.x > 1, limit: 10, select: p.id)
      end
      """

      opts = [mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: {:default, except: [:bound]}}]]
      diffs = ecto_diffs(src, opts)

      # No bump pair, and no bound drop either (the drop is the same family)…
      refute {"10", "11"} in diffs
      refute {"10", "9"} in diffs

      refute Enum.any?(diffs, fn {_o, mutated} ->
               mutated =~ "from(" and not (mutated =~ "limit")
             end)

      # …and the limit position carries no selector, while the where still weaves.
      mm = metamutant(src, opts)
      refute mm =~ ~r/limit:\s*\^case/
      assert mm =~ ~r/where:\s*\^case/

      assert_compiles(src, opts)
    end

    test "bumps a limit of 1 to both 2 and 0 (the lower bump reaches zero, still valid SQL)" do
      # The boundary *of* the bound bump: at n = 1 the `n > 0` clamp must still emit both bumps,
      # so `limit: 0` is offered. The other bound tests use n ∈ {10, 0}, neither of which
      # distinguishes `n > 0` from `n > 1`.
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", limit: 1, select: p.id)
      end
      """

      diffs = ecto_diffs(src)
      assert {"1", "2"} in diffs
      assert {"1", "0"} in diffs
    end

    test "bumps an offset and clamps the lower bound non-negative" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", offset: 0, select: p.id)
      end
      """

      diffs = ecto_diffs(src)

      assert {"0", "1"} in diffs
      # offset: -1 is invalid SQL — never offered.
      refute {"0", "-1"} in diffs
    end

    test "leaves a pinned limit's value to core (no literal bump)" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q(n), do: from(p in "posts", limit: ^n, select: p.id)
      end
      """

      # No integer literal in the bound, so no bump target: the only diff is the whole-`from`
      # drop, and the pinned bound is left raw (no woven selector in the limit position).
      assert [{_original, mutated}] = ecto_diffs(src)
      refute mutated =~ "limit"
      refute metamutant(src) =~ ~r/limit:\s*\^case/

      assert_compiles(src)
    end
  end

  describe "JoinType" do
    test "variant_labels/0 is the deduped source-kind vocabulary, in canonical order" do
      # Every flip table's keys, deduped — pins the three label strings against a
      # drifted/blanked/renamed constant. `join`/`inner_join` are never a flip source (widening is
      # deliberately not offered — see the moduledoc), so "inner" is not in this vocabulary. The
      # result is sorted, so it is stable regardless of `Map.keys` runtime iteration order.
      assert Mutare.Ecto.Query.variant_labels() == ["full", "left", "right"]
    end

    test "a default (inner) join has no join_type mutant — widening is not offered" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q do
          from p in Post,
            join: c in assoc(p, :comments),
            on: c.post_id == p.id,
            select: p.id
        end
      end
      """

      diffs = ecto_diffs(src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:join_type]}])

      assert diffs == []
      assert_compiles(src)
    end

    test "an explicit inner_join clause has no join_type mutant either" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in Post, inner_join: c in assoc(p, :comments), on: c.ok, select: p.id
        end
      end
      """

      diffs = ecto_diffs(src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:join_type]}])

      assert diffs == []
    end

    test "narrows an explicit left join back to inner" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q do
          from p in Post,
            left_join: c in assoc(p, :comments),
            on: c.post_id == p.id,
            select: p.id
        end
      end
      """

      diffs = ecto_diffs(src)

      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "inner_join: c in assoc" end)
      # Portable core: left↔inner only — no non-portable right without a dialect.
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "right_join" end)

      assert_compiles(src)
    end

    test "an explicit right_join/full_join clause with no dialect configured still narrows via the portable leg" do
      # `full_join` always narrows to `left_join` (portable, no gate); `right_join` has no
      # ungated narrowing target of its own (only `left_join`↔`right_join`, dialect-gated), so it
      # yields no mutant without a dialect. `Map.get(flips, key, [])` must default to `[]` (no
      # target), not `nil` (which would raise iterating `for to <- nil`).
      full =
        ecto_diffs(
          """
          defmodule M do
            import Ecto.Query
            def q do
              from p in Post, full_join: c in assoc(p, :comments), on: c.ok, select: p.id
            end
          end
          """,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:join_type]}]
        )

      assert Enum.any?(full, fn {_o, mutated} -> mutated =~ "left_join: c in assoc" end)
      refute Enum.any?(full, fn {_o, mutated} -> mutated =~ "right_join" end)

      right =
        ecto_diffs(
          """
          defmodule M2 do
            import Ecto.Query
            def q do
              from p in Post, right_join: c in assoc(p, :comments), on: c.ok, select: p.id
            end
          end
          """,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:join_type]}]
        )

      assert right == [], "expected no join_type mutant for right_join with no dialect configured"
    end
  end

  describe "Combination (intersect/except from clauses)" do
    test "swaps an intersect clause to except, keeping the combined query" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q(other) do
          from p in Post,
            select: p.id,
            intersect: ^other
        end
      end
      """

      diffs = ecto_diffs(src)

      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "except: ^other" end)
      # The swap preserves duplicate-handling: plain never becomes an `_all` variant.
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "except_all" end)

      assert_compiles(src)
    end

    test "swaps an except_all clause to intersect_all (the _all pair swaps as a pair)" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q(other) do
          from p in Post,
            select: p.id,
            except_all: ^other
        end
      end
      """

      diffs = ecto_diffs(src)

      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "intersect_all: ^other" end)
      # …and never the plain variant — `_all`-ness is preserved, so the set-op swap is not
      # conflated with a distinctness change.
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ ~r/intersect: \^other/ end)
    end

    test "a union clause has no combination swap (only the orthogonal clause drop)" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q(other) do
          from p in Post,
            select: p.id,
            union: ^other
        end
      end
      """

      # `union` has no principled single complement, so the :combination family stays silent.
      assert ecto_diffs(src, mutators: [{Mutare.Ecto, families: [:combination]}]) == []
    end
  end

  describe "Aggregate (in select / order_by)" do
    test "swaps an aggregate inside a from select clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", select: sum(p.views))
      end
      """

      assert {~s|from(p in "posts", select: sum(p.views))|,
              ~s|from(p in "posts", select: avg(p.views))|} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "reaches an aggregate nested in a map select" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", select: %{total: sum(p.views), peak: max(p.views)})
      end
      """

      diffs = ecto_diffs(src)
      orig = ~s|from(p in "posts", select: %{total: sum(p.views), peak: max(p.views)})|

      # Each aggregate swaps in place as its own single-point mutant — origin→target pinned so a
      # swap sourced from the wrong node (or an extra one) can't pass.
      assert {orig, ~s|from(p in "posts", select: %{total: avg(p.views), peak: max(p.views)})|} in diffs

      assert {orig, ~s|from(p in "posts", select: %{total: sum(p.views), peak: min(p.views)})|} in diffs
    end

    test "swaps an aggregate inside a from order_by clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", group_by: p.user_id, order_by: [desc: sum(p.views)])
      end
      """

      assert {~s|from(p in "posts", group_by: p.user_id, order_by: [desc: sum(p.views)])|,
              ~s|from(p in "posts", group_by: p.user_id, order_by: [desc: avg(p.views)])|} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end
  end

  describe "Arithmetic (in select / order_by)" do
    test "swaps an arithmetic operator inside a from select clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", select: p.views * p.weight)
      end
      """

      assert {~s|from(p in "posts", select: p.views * p.weight)|,
              ~s|from(p in "posts", select: p.views / p.weight)|} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "reaches an operator nested in a map select and under an aggregate" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", group_by: p.user_id, select: %{total: sum(p.views + p.bonus)})
      end
      """

      assert {~s|from(p in "posts", group_by: p.user_id, select: %{total: sum(p.views + p.bonus)})|,
              ~s|from(p in "posts", group_by: p.user_id, select: %{total: sum(p.views - p.bonus)})|} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end

    test "swaps an arithmetic operator inside a from order_by clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", order_by: [desc: p.views - p.penalty])
      end
      """

      assert {~s|from(p in "posts", order_by: [desc: p.views - p.penalty])|,
              ~s|from(p in "posts", order_by: [desc: p.views + p.penalty])|} in ecto_diffs(src)

      assert_compiles(src)
    end
  end

  # Each whole-`from` family keys off a specific clause type. These pin that the gate is the clause
  # *key*, not merely the clause *value's shape* — a constant in a `select`, an aggregate in a
  # `having`, or a direction in a `distinct` must not be mutated as if it were the gated clause.
  describe "clause gates — a family fires only on its own clause key" do
    defp family_diffs(code, family) do
      src = """
      defmodule GateFixture do
        import Ecto.Query
        def q, do: #{code}
      end
      """

      ecto_diffs(src, mutators: [{Mutare.Ecto, families: [family]}])
    end

    test "bound bumps fire only on limit/offset, not another integer-valued clause" do
      bounds = family_diffs("from(p in Post, select: 1, limit: 10)", :bound)

      # The literal `10` bumps both ways (hosted logical pairs); the `select: 1` constant is
      # never bumped — no diff anchors on it.
      assert {"10", "11"} in bounds
      assert {"10", "9"} in bounds
      refute Enum.any?(bounds, fn {original, _mutated} -> original == "1" end)
    end

    test "aggregate swaps fire on select/select_merge and order_by, but leave a hosted having alone" do
      diffs =
        family_diffs(
          "from(p in Post, having: sum(p.a) > 5, order_by: max(p.b), select: avg(p.c))",
          :aggregate
        )

      aggs =
        for {original, mutated} <- diffs,
            String.starts_with?(original, "from("),
            do: mutated

      # The `select` and `order_by` aggregates each swap in place — one single-point mutant each…
      assert "from(p in Post, having: sum(p.a) > 5, order_by: max(p.b), select: sum(p.c))" in aggs
      assert "from(p in Post, having: sum(p.a) > 5, order_by: min(p.b), select: avg(p.c))" in aggs
      assert length(aggs) == 2

      # …but the `having` aggregate is delivered through the host (`^`/`dynamic`), never as a
      # whole-`from` rewrite here, so Query leaves it untouched (no double-delivery).
      refute Enum.any?(aggs, &(&1 =~ "having: avg"))

      assert Enum.any?(diffs, fn {original, mutated} ->
               original == "sum(p.a) > 5" and mutated == "avg(p.a) > 5"
             end)
    end

    test "arithmetic swaps fire on select/order_by, but leave a hosted where alone" do
      diffs =
        family_diffs(
          "from(p in Post, where: p.a + p.b > 5, select: p.c * p.d)",
          :arithmetic
        )

      arith =
        for {original, mutated} <- diffs,
            String.starts_with?(original, "from("),
            do: mutated

      # The `select` operator swaps in place as a whole-`from` rewrite…
      assert arith == ["from(p in Post, where: p.a + p.b > 5, select: p.c / p.d)"]

      # …while the `where` operator is delivered through the host (`^`/`dynamic`) — its diff is
      # recorded at the condition, never as a whole-`from` rewrite here (no double-delivery).
      assert Enum.any?(diffs, fn {original, mutated} ->
               original == "p.a + p.b > 5" and mutated == "p.a - p.b > 5"
             end)
    end

    test "order flips fire only on order_by, not a direction in another clause" do
      flips =
        family_diffs(
          "from(p in Post, distinct: [desc: p.id], order_by: [asc: p.name])",
          :ordering
        )
        |> Enum.map(fn {_original, mutated} -> mutated end)

      # The order_by direction flips; the `distinct: [desc: p.id]` direction is left alone — so no
      # mutant flips it to `asc: p.id` (the flipped value renders bracket-less, like the order_by).
      assert Enum.any?(flips, &(&1 =~ "order_by: desc: p.name"))
      refute Enum.any?(flips, &(&1 =~ "asc: p.id"))
    end
  end
end
