defmodule Mutare.Ecto.ClauseDropTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Stage removal of a standalone/pipe query clause — `Mutare.Ecto.ClauseDrop`. The pipe form
  # becomes `Function.identity()` (`q |> where(…)` ≡ `q`), the direct form collapses to the query
  # argument (`where(q, …)` → `q`). This is the query-side twin of the changeset validator drop,
  # and the primary motivating mutation for a query builder. We also assert the routing change that
  # underlies it: a pipe stage no longer suppresses mutation of the upstream query.

  defp mutated(src, opts \\ []), do: Enum.map(ecto_diffs(src, opts), fn {_o, m} -> m end)

  describe "pipe form → Function.identity()" do
    test "drops a piped where (a filter)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> where([u], u.active)
      end
      """

      assert "Elixir.Function.identity()" in mutated(src)
      assert_compiles(src)
    end

    test "drops a piped select / limit / join / distinct / group_by stage" do
      # `order_by` is deliberately absent — it is not stage-droppable (an unordered query has an
      # unspecified row order, so the drop was an unreliable mutant); its ordering flip lives in
      # `Mutare.Ecto.Ordering` instead.
      for stage <- [
            "limit(10)",
            "offset(5)",
            "select([u], u.name)",
            ~s|join(:inner, [u], p in "posts", on: p.uid == u.id)|,
            "distinct(true)",
            "group_by([u], u.role)"
          ] do
        src = """
        defmodule M do
          import Ecto.Query
          def q(query), do: query |> #{stage}
        end
        """

        assert "Elixir.Function.identity()" in mutated(src),
               "expected a stage drop for: #{stage}"

        assert_compiles(src)
      end
    end
  end

  describe "direct form → collapses to the query argument" do
    test "collapses a directly-written where to its query" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [u], u.active)
      end
      """

      assert mutated(src) == ["query"]
      assert_compiles(src)
    end

    test "collapses a directly-written limit to its query (alongside the bound bumps)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: limit(query, 10)
      end
      """

      m = mutated(src)
      assert "query" in m
      # The bumps are hosted pin-only, so their diffs are the bare integers.
      assert "11" in m
      assert "9" in m
      assert_compiles(src)
    end
  end

  describe "families mirror the from-keyword clause drop" do
    @src """
    defmodule M do
      import Ecto.Query
      def q(query) do
        query
        |> where([u], u.active)
        |> limit(10)
        |> group_by([u], u.role)
      end
    end
    """

    test ":filter_drop drops the where stage only" do
      m = mutated(@src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:filter_drop]}])
      assert m == ["Elixir.Function.identity()"]
    end

    test ":bound drops the limit stage (and is where the n±1 bumps live too)" do
      m = mutated(@src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:bound]}])
      assert "Elixir.Function.identity()" in m
      # The bumps are hosted pin-only (bare-integer diffs), gated by the same `:bound` family.
      assert "11" in m
      assert "9" in m
    end

    test ":clause_drop drops the group_by stage (not where/limit, which have their own families)" do
      m = mutated(@src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:clause_drop]}])
      # group_by has no other family here, so its only mutation is the drop.
      assert m == ["Elixir.Function.identity()"]
    end
  end

  describe "resolution — only real Ecto.Query clauses" do
    test "does not fire on a same-named user function" do
      src = """
      defmodule M do
        def where(q, _), do: q
        def q(query), do: query |> where([:x])
      end
      """

      assert ecto_diffs(src) == []
    end
  end

  describe "routing fix — a pipe stage no longer suppresses upstream mutation" do
    test "the upstream from's where is mutated through a limit pipe stage" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in "users", where: u.age > 18) |> limit(10)
      end
      """

      # Previously the static-`:skip` `limit` stamped its piped value `:skip`, dropping every
      # mutation of the upstream `from`. Now the boundary swap on `u.age > 18` fires through it —
      # pinned as an exact origin→target pair so a same-text swap sourced elsewhere can't stand in.
      assert {"u.age > 18", "u.age >= 18"} in ecto_diffs(src)
      assert_compiles(src)
    end

    test "the upstream from's where is mutated through an order_by pipe stage" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in "users", where: u.age > 18) |> order_by([u], asc: u.name)
      end
      """

      assert {"u.age > 18", "u.age >= 18"} in ecto_diffs(src)
      assert_compiles(src)
    end
  end

  describe "family tag + totality (direct mutations/2)" do
    defp drop_mutations(code, pipe_mode) do
      Mutare.Ecto.ClauseDrop.mutations(
        Sourceror.parse_string!(code),
        context(pipe_mode: pipe_mode)
      )
    end

    test "a limit/offset stage drop is tagged :bound (parity with the from-keyword drop)" do
      # The family must key off membership in the bound set; a limit/offset drop is :bound, not the
      # catch-all :clause_drop.
      assert [%Mutare.Ecto.Tag{family: :bound}] =
               drop_mutations("Ecto.Query.limit(q, 10)", :unpiped)

      assert [%Mutare.Ecto.Tag{family: :bound}] =
               drop_mutations("Ecto.Query.offset(q, 5)", :unpiped)
    end

    test "a degenerate zero-arg droppable clause yields no mutant, never a crash" do
      # `where()` with no query arg hits the `drop(:unpiped, [])` path, which must return [] rather
      # than raising on the empty arg list.
      assert drop_mutations("Ecto.Query.where()", :unpiped) == []
    end
  end
end
