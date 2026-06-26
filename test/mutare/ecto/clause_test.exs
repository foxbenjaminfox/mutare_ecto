defmodule Mutare.Ecto.ClauseTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The standalone/pipe clause-macro mutations (`order_by`/`limit`/`offset` written as composable
  # calls, not `from` keywords). These ride `mutate/1` + Mutare's in-place selector — the macros
  # route through the `:routing` classifier (their data positions stay raw), but a routed node is
  # still offered to the mutator. We assert the logical diff is recorded and the metamutant
  # compiles. Stage *removal* of these clauses is covered in `clause_drop_test.exs`.

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

    test "an ordering without an explicit direction yields no flip (only the stage drop)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], u.name)
      end
      """

      # No explicit direction → no ordering flip. The stage drop still fires: the directly-written
      # `order_by(query, …)` collapses to its query argument (`Mutare.Ecto.ClauseDrop`).
      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      refute Enum.any?(mutated, &(&1 =~ "order_by"))
      assert mutated == ["query"]
    end

    test "a nulls-qualified direction splits into direction and placement axes" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u], desc_nulls_last: u.name)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      # direction axis (keep placement) + nulls axis (keep direction), and no combined flip.
      orderings = Enum.filter(mutated, &(&1 =~ "order_by"))
      assert "order_by([u], asc_nulls_last: u.name)" in orderings
      assert "order_by([u], desc_nulls_first: u.name)" in orderings
      assert length(orderings) == 2
      # …alongside the orthogonal stage drop (clause_drop → identity in the pipe form).
      assert Enum.any?(mutated, &(&1 =~ "identity"))
      assert_compiles(src)
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

    test "n = 1 bumps to both 2 and 0 (the lower bump reaches zero, which is valid SQL)" do
      # The boundary *of* the boundary bump: at n = 1 the `n > 0` clamp must still fire both
      # bumps, so `limit(0)` (an empty result) is offered. The other tests use n ∈ {10, 5, 0},
      # none of which distinguishes `n > 0` from `n > 1`.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> limit(1)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert "limit(2)" in mutated
      assert "limit(0)" in mutated
    end

    test "a pinned bound is not bumped (runtime value), but the stage is still dropped" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, n), do: query |> limit(^n)
      end
      """

      # `^n` is a runtime value, so there is no `n±1` literal bump — but dropping the whole `limit`
      # stage is valid regardless, so the only diff is the pipe-form drop (`:bound`).
      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert mutated == ["Elixir.Function.identity()"]
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

    test "swaps an aggregate in the direct (3-arg) select form, not just the pipe form" do
      # The pipe form (`q |> select([u], expr)`) carries 2 visible args, where splitting off the
      # last is indistinguishable from splitting off the first — so it can't pin *which* end the
      # select expression is taken from. The direct form has 3 (`select(q, [u], expr)`), so it
      # exercises `Enum.split(args, -1)` taking the trailing expression specifically.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: select(query, [u], sum(u.amount))
      end
      """

      assert Enum.any?(ecto_diffs(src), fn {_o, mutated} -> mutated =~ "avg(u.amount)" end)
      assert_compiles(src)
    end

    test "swaps an aggregate written into an order_by, alongside the direction flip" do
      # An `order_by` carries two independent mutation axes when its key is a sort direction *and*
      # its value is an aggregate: the direction flips (`:ordering`) and the aggregate swaps
      # (`:aggregate`) — neither subsumes the other, so both must appear.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u], desc: sum(u.amount))
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      # the aggregate swap (keep the direction)…
      assert Enum.any?(mutated, &(&1 =~ "desc: avg(u.amount)"))
      # …and the orthogonal direction flip (keep the aggregate).
      assert Enum.any?(mutated, &(&1 =~ "asc: sum(u.amount)"))
      assert_compiles(src)
    end
  end

  describe "totality — a degenerate zero-arg macro node yields no mutant, never a crash" do
    # `mutations/1` is offered every node in the source, so each clause guards `args != []`: it
    # protects the `{init, [last]} = Enum.split(args, -1)` destructuring, which would raise a
    # MatchError on `[]` rather than returning the no-op `[]`. A bare `order_by()`/`limit()`/
    # `select()` (no query, no value) is the degenerate node that exercises that guard.
    test "an empty-args order_by / limit / select returns []" do
      for code <- ["order_by()", "limit()", "offset()", "select()", "select_merge()"] do
        assert Mutare.Ecto.Clause.mutations(Sourceror.parse_string!(code)) == [],
               "expected no mutant for #{code}"
      end
    end
  end
end
