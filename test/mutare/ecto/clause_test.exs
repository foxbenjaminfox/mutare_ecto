defmodule Mutare.Ecto.ClauseTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The standalone/pipe clause-macro mutations (`order_by`/`limit`/`offset` written as composable
  # calls, not `from` keywords). These ride `mutate/1` + Mutare's in-place selector — the macros
  # are registered `:skip`, but a `:skip` node is still offered to the mutator. We assert the
  # logical diff is recorded and the metamutant compiles.

  describe "Ordering (standalone / pipe order_by)" do
    test "flips the direction in the pipe form" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u], asc: u.name)
      end
      """

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} -> mutated =~ "desc: u.name" end)
      assert_compiles(src)
    end

    test "flips the direction in the direct form (with a binding)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], desc: u.name)
      end
      """

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} -> mutated =~ "asc: u.name" end)
      assert_compiles(src)
    end

    test "flips each direction of a multi-key ordering independently" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], asc: u.name, desc: u.id)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert Enum.any?(mutated, &(&1 =~ "desc: u.name" and &1 =~ "desc: u.id"))
      assert Enum.any?(mutated, &(&1 =~ "asc: u.name" and &1 =~ "asc: u.id"))
    end

    test "an ordering without an explicit direction yields nothing" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], u.name)
      end
      """

      assert ecto_diffs(src) == []
    end
  end

  describe "Bound (standalone / pipe limit/offset)" do
    test "bumps a limit value both ways" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> limit(10)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert "limit(11)" in mutated
      assert "limit(9)" in mutated
      assert_compiles(src)
    end

    test "bumps an offset in the direct form" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: offset(query, 5)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert "offset(query, 6)" in mutated
      assert "offset(query, 4)" in mutated
    end

    test "clamps the lower bound non-negative" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> offset(0)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert "offset(1)" in mutated
      refute "offset(-1)" in mutated
    end

    test "leaves a pinned bound to core (no literal bump)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, n), do: query |> limit(^n)
      end
      """

      assert ecto_diffs(src) == []
      assert_compiles(src)
    end
  end

  describe "Aggregate (standalone / pipe select)" do
    test "swaps an aggregate in the pipe select form" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> select([u], sum(u.amount))
      end
      """

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} -> mutated =~ "avg(u.amount)" end)
      assert_compiles(src)
    end

    test "swaps an aggregate inside a select_merge map" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> select_merge([u], %{peak: max(u.x)})
      end
      """

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} -> mutated =~ "min(u.x)" end)
      assert_compiles(src)
    end
  end
end
