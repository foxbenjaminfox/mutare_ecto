defmodule Mutare.Ecto.ClauseTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  alias Mutare.Ecto.AST.QueryCall
  alias Mutare.Transform.Meta

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

      assert {"order_by([u], asc: u.name)", "order_by([u], desc: u.name)"} in ecto_diffs(src)
      assert_compiles(src)
    end

    test "flips the direction in the direct form (with a binding)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], desc: u.name)
      end
      """

      assert {"order_by(query, [u], desc: u.name)", "order_by(query, [u], asc: u.name)"} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end

    test "flips each direction of a multi-key ordering independently" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], asc: u.name, desc: u.id)
      end
      """

      diffs = ecto_diffs(src)
      orig = "order_by(query, [u], asc: u.name, desc: u.id)"

      # Each key flips independently — never both at once. `order_by` is deliberately not
      # stage-droppable: an unordered query has SQL-unspecified row order, so that old drop was an
      # unreliable mutant.
      assert {orig, "order_by(query, [u], desc: u.name, desc: u.id)"} in diffs
      assert {orig, "order_by(query, [u], asc: u.name, asc: u.id)"} in diffs
      assert length(diffs) == 2
      assert_compiles(src)
    end

    test "an ordering without an explicit direction re-tags its implicit asc to desc" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], u.name)
      end
      """

      # A bare `u.name` is ascending by definition, so the only mutation is the implicit-direction
      # flip (`order_by(query, [u], desc: u.name)`). `order_by` is deliberately not stage-droppable
      # — dropping an ORDER BY leaves an unspecified row order, an unreliable mutant.
      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert mutated == ["order_by(query, [u], desc: u.name)"]
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
      # `order_by` is not stage-droppable, so there is no identity/drop mutant to accompany them.
      refute Enum.any?(mutated, &(&1 =~ "identity"))
      assert_compiles(src)
    end
  end

  describe "Bound (standalone / pipe limit/offset)" do
    test "bumps a limit value both ways (woven pin-only, not a rebuilt call)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> limit(10)
      end
      """

      diffs = ecto_diffs(src)
      # The recorded diff is the logical pair alone — the hosted pin-only bump, no call rewrite.
      assert {"10", "11"} in diffs
      assert {"10", "9"} in diffs
      # Delivery shape: the selector is pinned straight into the bound argument, with no
      # `dynamic/2` wrap — the branches are bare integers.
      mm = metamutant(src)
      assert mm =~ ~r/limit\(\s*\^case/
      refute mm =~ "dynamic"
      assert_compiles(src)
    end

    test "bumps an offset in the direct form" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: offset(query, 5)
      end
      """

      diffs = ecto_diffs(src)
      assert {"5", "6"} in diffs
      assert {"5", "4"} in diffs
    end

    test "clamps the lower bound non-negative" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> offset(0)
      end
      """

      diffs = ecto_diffs(src)
      assert {"0", "1"} in diffs
      refute {"0", "-1"} in diffs
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

      diffs = ecto_diffs(src)
      assert {"1", "2"} in diffs
      assert {"1", "0"} in diffs
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

      assert {"sum(u.amount)", "avg(u.amount)"} in ecto_diffs(src)
      assert_compiles(src)
    end

    test "swaps an aggregate inside a select_merge map" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> select_merge([u], %{peak: max(u.x)})
      end
      """

      assert {"max(u.x)", "min(u.x)"} in ecto_diffs(src)

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

      assert {"sum(u.amount)", "avg(u.amount)"} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "swaps an aggregate written into an order_by, alongside the direction flip" do
      # An `order_by` carries two independent mutation axes when its key is a sort direction *and*
      # its value is an aggregate: the direction flips (`:ordering`) and the aggregate swaps
      # (`:aggregate`) — neither subsumes the other, so both must appear. Pin each exact pair (not a
      # loose substring), so a swap sourced from the wrong node or a stray extra mutant is caught.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u], desc: sum(u.amount))
      end
      """

      diffs = ecto_diffs(src)
      # the aggregate swap (keep the direction)…
      assert {"sum(u.amount)", "avg(u.amount)"} in diffs
      # …and the orthogonal direction flip (keep the aggregate).
      assert {"order_by([u], desc: sum(u.amount))", "order_by([u], asc: sum(u.amount))"} in diffs
      assert_compiles(src)
    end
  end

  describe "Combination (standalone / pipe intersect/except)" do
    test "swaps intersect to except in the pipe form, keeping the operand query" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, other), do: query |> intersect(^other)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert "except(^other)" in mutated
      # The swap preserves duplicate-handling — never the `_all` variant…
      refute Enum.any?(mutated, &(&1 =~ "except_all"))
      # …alongside the orthogonal stage drop (`q |> intersect(…)` → `q`, as identity).
      assert Enum.any?(mutated, &(&1 =~ "identity"))
      assert_compiles(src)
    end

    test "swaps except_all to intersect_all in the direct form (the _all pair swaps as a pair)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, other), do: except_all(query, ^other)
      end
      """

      mutated = Enum.map(ecto_diffs(src), fn {_o, m} -> m end)
      assert "intersect_all(query, ^other)" in mutated
      refute Enum.any?(mutated, &(&1 =~ ~r/intersect\(/))
      assert_compiles(src)
    end

    test "a union stage has no combination swap (only the orthogonal stage drop)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, other), do: query |> union(^other)
      end
      """

      # `union` has no principled single complement, so the :combination family stays silent.
      assert ecto_diffs(src, mutators: [{Mutare.Ecto, families: [:combination]}]) == []
    end
  end

  describe "Arithmetic (standalone / pipe select)" do
    test "swaps an arithmetic operator in the pipe select form" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> select([u], u.price * u.qty)
      end
      """

      assert {"u.price * u.qty", "u.price / u.qty"} in ecto_diffs(src)
      assert_compiles(src)
    end

    test "swaps an arithmetic operator inside a select_merge map" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> select_merge([u], %{net: u.gross - u.tax})
      end
      """

      assert {"u.gross - u.tax", "u.gross + u.tax"} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "swaps an arithmetic operator written into an order_by, alongside the direction flip" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u], desc: u.a + u.b)
      end
      """

      diffs = ecto_diffs(src)
      # the arithmetic swap (keep the direction)…
      assert {"u.a + u.b", "u.a - u.b"} in diffs
      # …and the orthogonal direction flip (keep the operator).
      assert {"order_by([u], desc: u.a + u.b)", "order_by([u], asc: u.a + u.b)"} in diffs
      assert_compiles(src)
    end
  end

  describe "Coalesce (standalone / pipe select / order_by)" do
    test "drops the fallback of a coalesce written into a pipe select" do
      # `scalar.ex` owns the Coalesce fallback drop *and* the Arithmetic swaps, walked over
      # `select`/`order_by` values — so the drop must be delivered through a standalone clause, not
      # merely catalogued in `scalar_test`.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> select([u], coalesce(u.score, 0))
      end
      """

      assert {"coalesce(u.score, 0)", "u.score"} in ecto_diffs(src)
      assert_compiles(src)
    end

    test "drops the fallback of a coalesce in an order_by value, alongside the direction flip" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], asc: coalesce(u.score, 0))
      end
      """

      diffs = ecto_diffs(src)
      # the coalesce fallback drop (keep the direction)…
      assert {"coalesce(u.score, 0)", "u.score"} in diffs

      # …and the orthogonal direction flip (keep the coalesce).
      assert {"order_by(query, [u], asc: coalesce(u.score, 0))",
              "order_by(query, [u], desc: coalesce(u.score, 0))"} in diffs

      assert_compiles(src)
    end
  end

  describe "totality — a degenerate zero-arg macro node yields no mutant, never a crash" do
    # Every clause macro reaches `Clause.mutations/2` already normalized into a `%QueryCall{}` by
    # `Mutare.Ecto.Dispatcher` (which parses the resolved, macro-identity-stamped node first), so
    # each clause here guards `args != []` against that shape: it protects the
    # `{init, [last]} = Enum.split(args, -1)` destructuring, which would raise a MatchError on `[]`
    # rather than returning the no-op `[]`. A bare `order_by()`/`limit()`/`select()` (no query, no
    # value) is the degenerate call that exercises that guard — built directly as a stamped
    # `%QueryCall{}` (mirroring `Mutare.Ecto.NormalizedASTTest`) since a real zero-arg call has no
    # matching macro arity to route through the full pipeline.
    test "an empty-args order_by / limit / select returns []" do
      for name <- [:order_by, :limit, :offset, :select, :select_merge, :intersect] do
        {head, meta, args} = Sourceror.parse_string!("#{name}()")
        meta = Meta.stamp_macro_call(meta, {Mutare.Calls.module_key(Ecto.Query), name, :unpiped})
        call = QueryCall.parse({head, meta, args})

        assert %QueryCall{name: ^name, args: []} = call

        assert Mutare.Ecto.Clause.mutations(call, %{}) == [],
               "expected no mutant for #{name}()"
      end
    end
  end
end
