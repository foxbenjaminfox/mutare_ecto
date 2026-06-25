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

    drops = Enum.filter(ecto_diffs(src), fn {_original, mutated} -> mutated =~ "from" end)

    # Two where clauses → two drop mutants; the surviving query keeps select and one where.
    assert length(drops) >= 2
    assert Enum.any?(drops, fn {_original, mutated} -> not (mutated =~ "active") end)
    assert Enum.any?(drops, fn {_original, mutated} -> not (mutated =~ "deleted") end)
  end

  test "drops a where clause (bindingless keyword form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from("posts", where: [active: true], select: [:id])
    end
    """

    assert Enum.any?(ecto_diffs(src), fn {_original, mutated} -> not (mutated =~ "active") end)
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

  test "does not fire on a plain (non-from) call" do
    src = """
    defmodule M do
      def q(x), do: from_cache(x)
    end
    """

    assert ecto_diffs(src) == []
  end

  describe "Bound (limit/offset)" do
    test "drops a limit clause and bumps its value by ±1" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", limit: 10, select: p.id)
      end
      """

      diffs = ecto_diffs(src)

      # The whole-`from` drop removes the limit (the surviving query keeps select).
      assert Enum.any?(diffs, fn {_o, mutated} ->
               mutated =~ "from" and not (mutated =~ "limit")
             end)

      # And the literal bound bumps off-by-one both ways.
      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "limit: 11" end)
      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "limit: 9" end)
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
      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "limit: 2" end)
      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "limit: 0" end)
    end

    test "bumps an offset and clamps the lower bound non-negative" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", offset: 0, select: p.id)
      end
      """

      diffs = ecto_diffs(src)

      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "offset: 1" end)
      # offset: -1 is invalid SQL — never offered.
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "offset: -1" end)
    end

    test "leaves a pinned limit's value to core (no literal bump)" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q(n), do: from(p in "posts", limit: ^n, select: p.id)
      end
      """

      # No integer literal in the bound, so only the drop fires — no bump mutant.
      refute Enum.any?(ecto_diffs(src), fn {_o, mutated} ->
               mutated =~ "limit:" and mutated =~ ~r/limit: \d/
             end)

      assert_compiles(src)
    end
  end

  describe "JoinType" do
    test "swaps a default (inner) join to a left join" do
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

      diffs = ecto_diffs(src)

      assert Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "left_join: c in assoc" end)
      # The portable core stays inner↔left — no non-portable right/full/cross.
      refute Enum.any?(diffs, fn {_o, mutated} -> mutated =~ "right_join" end)

      assert_compiles(src)
    end

    test "swaps an explicit left join back to inner" do
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

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} ->
               mutated =~ "inner_join: c in assoc"
             end)
    end
  end

  describe "Aggregate (in select)" do
    test "swaps an aggregate inside a from select clause" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", select: sum(p.views))
      end
      """

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} -> mutated =~ "avg(p.views)" end)
      assert_compiles(src)
    end

    test "reaches an aggregate nested in a map select" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", select: %{total: sum(p.views), peak: max(p.views)})
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert Enum.any?(mutated, &(&1 =~ "avg(p.views)"))
      assert Enum.any?(mutated, &(&1 =~ "min(p.views)"))
    end
  end
end
