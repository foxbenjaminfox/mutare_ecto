defmodule Mutare.Ecto.DslAuditRegressionTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  defp fixture(body) do
    """
    defmodule AuditQuery do
      import Ecto.Query
      alias MyApp.{Post, User}
      def q do
        #{body}
      end
    end
    """
  end

  defp only(families),
    do: [mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: families}]]

  defp assert_rewrite(source, families, before, after_code) do
    diffs = ecto_diffs(source, only(families))

    assert Enum.any?(diffs, fn {original, mutated} ->
             String.contains?(original, before) and String.contains?(mutated, after_code)
           end),
           "missing #{inspect(before)} -> #{inspect(after_code)}; got #{inspect(diffs)}"
  end

  test "window syntax stays structural inside a value dynamic" do
    for window <- [
          "partition_by: p.user_id",
          "order_by: [desc: p.views + 1]",
          "partition_by: [:user_id], order_by: [desc: :views]",
          ":by_user"
        ] do
      source =
        fixture("""
        total = dynamic([p], over(sum(p.views), #{window}))
        from p in Post, windows: [by_user: [partition_by: p.user_id]], select: ^total
        """)

      assert ecto_diffs(source, only([:atom_literal])) == []
      assert_builds(source, & &1.q(), only([:atom_literal]))
      assert_rewrite(source, [:aggregate], "sum(p.views)", "avg(p.views)")
      assert_builds(source, & &1.q(), only([:aggregate, :arithmetic]))
    end
  end

  test "a list-valued dynamic is an expression" do
    source =
      fixture("""
      values = dynamic([p], [p.views + 1])
      from p in Post, select: ^values
      """)

    assert_rewrite(source, [:arithmetic], "p.views + 1", "p.views - 1")
    assert_builds(source, & &1.q(), only([:arithmetic]))
  end

  test "map values and selected aliases in a dynamic retain their expression sites" do
    for body <- ["%{value: p.views + 1}", "selected_as(p.views + 1, :metric)"] do
      source = fixture("value = dynamic([p], #{body}); from p in Post, select: ^value")
      assert_rewrite(source, [:arithmetic], "p.views + 1", "p.views - 1")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "repeated explicit on predicates receive static mutations in both spellings" do
    for query <- [
          "from u in User, join: p in Post, on: p.user_id == u.id, on: p.views > 10, select: {u.id, p.id}",
          "User |> join(:inner, [u], p in Post, on: p.user_id == u.id, on: p.views > 10) |> select([u, p], {u.id, p.id})"
        ] do
      source = fixture(query)
      assert_rewrite(source, [:comparison], "p.user_id == u.id", "p.user_id != u.id")
      assert_rewrite(source, [:comparison], "p.views > 10", "p.views >= 10")
      assert_builds(source, & &1.q(), only([:comparison]))
    end
  end

  test "association joins admit one explicit dynamic predicate" do
    source =
      fixture("""
      from u in User, join: p in assoc(u, :posts), on: p.views > 10, select: {u.id, p.id}
      """)

    assert_rewrite(source, [:comparison], "p.views > 10", "p.views >= 10")
    assert_builds(source, & &1.q(), only([:comparison]))
  end

  test "EXISTS observes a projection across EXCEPT and INTERSECT" do
    for combination <- [:except, :intersect, :except_all, :intersect_all] do
      source =
        fixture("""
        right = from p in Post, select: p.views
        from u in User,
          where: exists(from p in Post, select: p.views + 1, #{combination}: ^right),
          select: u.id
        """)

      assert_rewrite(source, [:arithmetic], "p.views + 1", "p.views - 1")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "terminal conditions of composed inline subqueries remain reachable" do
    for inner <- [
          "Post |> where([p], p.views > 10)",
          "where(Post, [p], p.views > 10)",
          "Post |> where([p], p.views > 10) |> select([p], p.id)"
        ],
        wrapper <- ["exists", "subquery", "exists_subquery"] do
      predicate =
        case wrapper do
          "exists" -> "exists(#{inner})"
          "exists_subquery" -> "exists(subquery(#{inner}))"
          "subquery" -> "u.id in subquery(#{inner})"
        end

      source = fixture("from u in User, where: #{predicate}, select: u.id")
      assert_rewrite(source, [:comparison], "p.views > 10", "p.views >= 10")
      assert_builds(source, & &1.q(), only([:comparison]))
      assert length(ecto_diffs(source, only([:comparison]))) == 1
    end
  end

  test "a scalar top-one subquery exposes ordering and bounds" do
    source =
      fixture("""
      from u in User,
        where: u.age > subquery(from p in Post,
          order_by: [desc: p.views, desc: p.id], limit: 1, select: p.views),
        select: u.id
      """)

    assert_rewrite(source, [:ordering], "desc: p.views", "asc: p.views")
    assert_rewrite(source, [:bound], "limit: 1", "limit: ^0")
    assert_builds(source, & &1.q(), only([:ordering, :bound]))
  end

  test "EXISTS offsets and zero-crossing limits are observable bounds" do
    for bound <- ["offset: 1", "limit: 1"] do
      source = fixture("from u in User, where: exists(from p in Post, #{bound}, select: p.id)")
      key = if bound == "offset: 1", do: "offset", else: "limit"
      assert_rewrite(source, [:bound], bound, "#{key}: ^0")
      assert_builds(source, & &1.q(), only([:bound]))
    end
  end
end
