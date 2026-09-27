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

  defp assert_native_builds(source) do
    native = compile_native(source)
    assert %Ecto.Query{} = Ecto.Queryable.to_query(native.q())
  end

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

  test "a coalesce drop is withheld where the parent refuses what it wraps" do
    # `nil > 0` is a forbidden comparison with nil; a bare comparison is not a `type/2` operand.
    for clause <- ["where", "select"],
        refused <- [
          "coalesce(nil, p.value) > 0",
          "type(coalesce(p.value > 0, false), :boolean)"
        ] do
      source = fixture(~s|from p in "audit_rows", #{clause}: #{refused}|)
      assert_native_builds(source)
      assert ecto_diffs(source, only([:coalesce])) == []
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  test "a coalesce drop is kept where the parent accepts what it wraps" do
    for clause <- ["where", "select"],
        {parent, coalesce} <- [
          {"coalesce(p.value, nil) > 0", "coalesce(p.value, nil)"},
          {"type(coalesce(p.value, 0), :integer) > 0", "coalesce(p.value, 0)"}
        ] do
      source = fixture(~s|from p in "audit_rows", #{clause}: #{parent}|)
      assert_rewrite(source, [:coalesce], coalesce, "p.value")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  test "beneath is_nil, a window's options are observed by value" do
    # (a, b, value) = (1, 1, NULL), (2, 0, 10): addition puts both rows in one partition, whose
    # sum is 10; subtraction separates them, and the first row's partition sums to NULL. An
    # ordering key under a row frame picks the frame's rows the same way.
    for window <- [
          "partition_by: p.a + p.b",
          ~s|order_by: p.a + p.b, frame: fragment("ROWS BETWEEN 1 PRECEDING AND CURRENT ROW")|
        ] do
      source =
        fixture("""
        result = dynamic([p], is_nil(over(sum(p.value), #{window})))
        from p in "audit_rows", select: ^result
        """)

      assert_native_builds(source)
      assert_rewrite(source, [:arithmetic], "p.a + p.b", "p.a - p.b")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "beneath is_nil, a window's function keeps the NULL-ness observation" do
    # Over the rows the window selects, `sum` and `avg` are NULL together.
    source =
      fixture("""
      result = dynamic([p], is_nil(over(sum(p.value), partition_by: p.a)))
      from p in "audit_rows", select: ^result
      """)

    assert ecto_diffs(source, only([:aggregate])) == []
  end

  test "EXISTS observes a projection that can decide whether a row survives" do
    for inner <- [
          # A deduplication and an offset that may skip what it leaves.
          ~s|from r in "audit_rows", select: r.a + r.b, union: ^right, offset: 1|,
          ~s|from r in "audit_rows", distinct: true, select: r.a + r.b, offset: 1|,
          ~s|from r in "audit_rows", distinct: ^flag, select: r.a + r.b, offset: ^skip|,
          # A projected value read back through its alias.
          ~s|from r in "audit_rows", group_by: r.id, having: selected_as(:total) > 1, select: selected_as(sum(r.a + r.b), :total)|,
          # A source whose own clauses (here a deduplication and an offset) are out of view.
          ~s|from r in base, select: r.a + r.b|
        ] do
      source =
        fixture("""
        {flag, skip} = {true, 1}
        right = from r in "audit_rows", select: 2
        base = from r in "audit_rows", distinct: true, offset: 1
        from p in "audit_rows", where: exists(#{inner}), select: p.id
        """)

      assert_native_builds(source)
      assert_rewrite(source, [:arithmetic], "r.a + r.b", "r.a - r.b")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "EXISTS still prunes a projection that cannot decide whether a row survives" do
    for inner <- [
          ~s|from r in "audit_rows", select: r.a + r.b, union: ^right|,
          ~s|from r in "audit_rows", select: r.a + r.b, union: ^right, offset: 0|,
          ~s|from r in "audit_rows", select: r.a + r.b, union_all: ^right, offset: 1|,
          ~s|from r in "audit_rows", distinct: r.a, select: r.a + r.b, offset: 1|,
          ~s|from r in "audit_rows", select: selected_as(r.a + r.b, :total), order_by: selected_as(:total)|
        ] do
      source =
        fixture("""
        right = from r in "audit_rows", select: 2
        from p in "audit_rows", where: exists(#{inner}), select: p.id
        """)

      assert_native_builds(source)
      assert ecto_diffs(source, only([:arithmetic])) == []
    end
  end

  test "an EXISTS limit drop is kept unless the limit it uncovers matches in zero-ness" do
    # `n` and `base` are passed in, so `base`'s own `limit: 0` is no site of the fixture.
    import Ecto.Query
    build = & &1.q(0, from(r in "audit_rows", limit: 0))

    drops = fn inner ->
      source = """
      defmodule AuditQuery do
        import Ecto.Query
        def q(n, base) do
          from p in "audit_rows", where: exists(#{inner}), select: p.id
        end
      end
      """

      assert %Ecto.Query{} =
               source |> compile_native() |> then(build) |> Ecto.Queryable.to_query()

      assert_builds(source, build, only([:bound]))

      for site <- sites(source, only([:bound])),
          site.operation == :delete,
          do: String.trim(site.original_code)
    end

    # The drop uncovers an overridden zero, lifts a runtime zero, or uncovers the source's limit.
    # Neither bump of 5 crosses zero, so the drop is the only mutant that can change existence.
    assert drops.(~s|from r in "audit_rows", limit: 0, limit: 5, select: r.id|) == ["5"]
    assert drops.(~s|from r in "audit_rows", limit: ^n, select: r.id|) == ["^n"]
    assert drops.(~s|from r in base, limit: 5, select: r.id|) == ["5"]

    # A nonzero limit uncovering a nonzero limit, or no limit at all, is equivalent.
    assert drops.(~s|from r in "audit_rows", limit: 3, limit: 5, select: r.id|) == []
    assert drops.(~s|from r in "audit_rows", limit: 5, select: r.id|) == []
  end
end
