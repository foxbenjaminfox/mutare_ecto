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

    # Two where clauses → exactly two whole-`from` drop mutants, now each reported (as a
    # deletion) at its own clause rather than at the whole `from`. Pinned as exact pairs so a
    # wrong-clause drop, a missing drop, or an over-mutation can't slip past.
    drops = Enum.filter(ecto_diffs(src), fn {_original, mutated} -> mutated == "" end)
    assert drops == [{"p.active", ""}, {"not p.deleted", ""}]
  end

  test "drops a where clause (bindingless keyword form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from("posts", where: [active: true], select: [:id])
    end
    """

    # The lone where drops, keeping the select — now reported (as a deletion) at the where
    # clause itself rather than at the whole `from`. The exact and only mutant.
    assert ecto_diffs(src) == [{"[active: true]", ""}]
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

  describe "the piped from (`Post |> from(…)`)" do
    # The source is the `|>` left side, so the whole-`from` rewrites read the call's one visible
    # argument as the clause list (`Mutare.Ecto.AST.FromCall`, by `pipe_mode`) and rebuild only
    # the `from(…)` half — the pipe and its source are never re-emitted.
    test "drops each filter and the bound, rebuilding the from(…) half only" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: Post |> from(where: [active: true], where: [deleted: false], limit: 10)
      end
      """

      drops = Enum.filter(ecto_diffs(src), fn {_original, mutated} -> mutated == "" end)
      assert drops == [{"[active: true]", ""}, {"[deleted: false]", ""}, {"10", ""}]

      # Core hoists a piped stage with whole-call mutants into a closure over the pipe's left side
      # (`Post |> (fn mutare_piped -> case … end).()`), so each drop mutant is `mutare_piped |>
      # from(…)` with one clause fewer — the source is never re-emitted into the call.
      mm = metamutant(src)
      assert mm =~ "mutare_piped |> from(where: [deleted: false], limit: 10)"
      assert mm =~ "mutare_piped |> from(where: [active: true], limit: 10)"
      assert mm =~ "mutare_piped |> from(where: [active: true], where: [deleted: false])"
      refute mm =~ "from(Post"
      assert_compiles(src)
    end

    test "dropping the last clause collapses to the argless `from()`" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: Post |> from(where: [active: true])
      end
      """

      assert ecto_diffs(src) == [{"[active: true]", ""}]

      # The piped twin of the `from(source)` collapse — never `from([])`. (`mutare_piped` is core's
      # hoisted pipe-left variable — see the drop test above.)
      assert metamutant(src) =~ "mutare_piped |> from()"
      assert_compiles(src)
    end

    test "yields exactly the direct form's mutants" do
      piped = """
      defmodule Posts do
        import Ecto.Query
        def q do
          Post
          |> from(
            as: :post,
            left_join: c in "comments",
            on: c.post_id == as(:post).id,
            where: as(:post).views > 1,
            order_by: [asc: as(:post).name],
            limit: 10,
            select: sum(as(:post).views)
          )
        end
      end
      """

      direct = """
      defmodule Posts do
        import Ecto.Query
        def q do
          from(
            Post,
            as: :post,
            left_join: c in "comments",
            on: c.post_id == as(:post).id,
            where: as(:post).views > 1,
            order_by: [asc: as(:post).name],
            limit: 10,
            select: sum(as(:post).views)
          )
        end
      end
      """

      assert ecto_diffs(piped) == ecto_diffs(direct)

      # Every whole-`from` producer fires: the join narrowing, the ordering flip, the aggregate
      # swap — and the hosted `on:` re-declares the join binding past the hidden source (`[..., c]`).
      assert {"left_join:", "inner_join:"} in ecto_diffs(piped)
      assert Enum.any?(ecto_diffs(piped), fn {_o, m} -> m =~ "desc: as(:post).name" end)
      assert {"sum(as(:post).views)", "avg(as(:post).views)"} in ecto_diffs(piped)
      assert {"c.post_id == as(:post).id", "c.post_id != as(:post).id"} in ecto_diffs(piped)
      assert metamutant(piped) =~ "dynamic([..., c], c.post_id"
      assert_compiles(piped)
    end
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

      # The whole-`from` drop removes the limit — now reported (as a deletion) at the limit
      # clause value itself, not at the whole `from`…
      assert {"10", ""} in diffs

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

    test "mutates only the last of a repeated bound — Ecto lets a later limit/offset override" do
      # Ecto applies a `from`'s pairs in order and `limit`/`offset` *replace* their predecessor, so
      # of `limit: 5, limit: 10` only the `10` is ever in the query: every mutant of the `5` — both
      # bumps and its drop — would leave the built query unchanged. The last occurrence keeps all
      # three, and its drop is live: it uncovers the `5` (`FromCall.effective_clause?/2`).
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", limit: 5, limit: 10, offset: 1, offset: 2, select: p.id)
      end
      """

      diffs = ecto_diffs(src)

      # The effective bounds carry their bumps…
      assert {"10", "11"} in diffs
      assert {"10", "9"} in diffs
      assert {"2", "3"} in diffs
      assert {"2", "1"} in diffs
      # …and their drops, reported at the dropped value…
      assert {"10", ""} in diffs
      assert {"2", ""} in diffs
      # …while the overridden ones yield nothing at all: no bump, no drop.
      refute Enum.any?(diffs, fn {original, _mutated} -> original in ["5", "1"] end)

      # Delivery: one pin-only weave per effective bound; the overridden literals stay as written.
      mm = metamutant(src)
      assert length(Regex.scan(~r/limit:\s*\^case/, mm)) == 1
      assert length(Regex.scan(~r/offset:\s*\^case/, mm)) == 1
      assert mm =~ "limit: 5"
      assert mm =~ "offset: 1"

      assert_compiles(src)
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
    test "variant_labels/0 is the source-kind vocabulary" do
      # Every flip table's keys — pins the three label strings against a drifted/blanked/renamed
      # constant. `join`/`inner_join` are never a flip source (widening is deliberately not
      # offered — see the moduledoc), so "inner" is not in this vocabulary. The raw contribution
      # is unordered and repeats `left` (a source in both tables); `Mutare.Ecto.variants/0` is
      # where the union is canonicalised (`Mutare.Ecto.Vocabulary`).
      labels = Mutare.Ecto.Query.variant_labels()
      assert Enum.sort(Enum.uniq(labels)) == ["full", "left", "right"]
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

      # The swap is now reported at the join clause key itself (`left_join:` → `inner_join:`).
      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "inner_join:" end)
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

      assert Enum.any?(full, fn {_o, mutated} -> mutated =~ "left_join:" end)
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

      # The swap is now reported at the set-op clause key itself (`intersect:` → `except:`).
      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "except:" end)
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

      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "intersect_all:" end)
      # …and never the plain variant — `_all`-ness is preserved, so the set-op swap is not
      # conflated with a distinctness change.
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated == "intersect:" end)
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

      assert {"sum(p.views)", "avg(p.views)"} in ecto_diffs(src)

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

      # Each aggregate swaps in place as its own single-point mutant — reported at the swapped
      # call's own node (the walk stamps node-level attribution), not the enclosing select
      # clause. origin→target pinned so a swap sourced from the wrong node (or an extra one)
      # can't pass.
      assert {"sum(p.views)", "avg(p.views)"} in diffs
      assert {"max(p.views)", "min(p.views)"} in diffs
    end

    test "swaps an aggregate inside a from order_by clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", group_by: p.user_id, order_by: [desc: sum(p.views)])
      end
      """

      assert {"sum(p.views)", "avg(p.views)"} in ecto_diffs(src)

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

      assert {"p.views * p.weight", "p.views / p.weight"} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "reaches an operator nested in a map select and under an aggregate" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", group_by: p.user_id, select: %{total: sum(p.views + p.bonus)})
      end
      """

      assert {"p.views + p.bonus", "p.views - p.bonus"} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "swaps an arithmetic operator inside a from order_by clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", order_by: [desc: p.views - p.penalty])
      end
      """

      assert {"p.views - p.penalty", "p.views + p.penalty"} in ecto_diffs(src)

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

      # Each aggregate swaps exactly once, now reported at its own clause: the `order_by` and
      # `select` aggregates as whole-`from` rewrites (Query), the `having` aggregate through the
      # host (`^`/`dynamic`). No aggregate is double-delivered — the diff set is exactly these
      # three, and a Query rewrite of the hosted `having` would show up as a fourth (duplicate).
      assert Enum.sort(diffs) ==
               Enum.sort([
                 {"max(p.b)", "min(p.b)"},
                 {"avg(p.c)", "sum(p.c)"},
                 {"sum(p.a) > 5", "avg(p.a) > 5"}
               ])
    end

    test "arithmetic swaps fire on select/order_by, but leave a hosted where alone" do
      diffs =
        family_diffs(
          "from(p in Post, where: p.a + p.b > 5, select: p.c * p.d)",
          :arithmetic
        )

      # The `select` operator swaps as a whole-`from` rewrite (Query), reported at the select
      # value; the `where` operator is delivered through the host (`^`/`dynamic`), reported at the
      # condition — each exactly once (no double-delivery).
      assert Enum.sort(diffs) ==
               Enum.sort([
                 {"p.c * p.d", "p.c / p.d"},
                 {"p.a + p.b > 5", "p.a - p.b > 5"}
               ])
    end

    test "order flips fire only on order_by, not a direction in another clause" do
      flips =
        family_diffs(
          "from(p in Post, distinct: [desc: p.id], order_by: [asc: p.name])",
          :ordering
        )
        |> Enum.map(fn {_original, mutated} -> mutated end)

      # The order_by direction flips (reported at the order_by value); the `distinct: [desc: p.id]`
      # direction is left alone — so the only mutant is the order_by flip, never one touching
      # `p.id`.
      assert flips == ["[desc: p.name]"]
    end
  end
end
