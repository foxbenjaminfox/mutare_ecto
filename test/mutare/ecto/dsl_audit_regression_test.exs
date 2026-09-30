defmodule Mutare.Ecto.DslAuditMacros do
  @moduledoc false
  # Unregistered author macros: no call routes, so only Ecto's expansion shows what they are.
  defmacro positive_alias, do: quote(do: selected_as(:n) > 1)
  defmacro total(x), do: quote(do: sum(unquote(x)))
  defmacro ignore(_condition), do: true
  # Ecto's own names at arities Ecto does not have, so Ecto expands them.
  defmacro coalesce(value), do: value
  defmacro fragment, do: true
  defmacro sum(left, right), do: quote(do: sum(unquote(left) + unquote(right)))
  defmacro like(value), do: quote(do: like(unquote(value), "ok%"))
  defmacro aliased(value), do: quote(do: selected_as(unquote(value), :bucket))
  # Ecto's names that are grammar of one position only: `map/2` in a select, `constant/1` as a
  # fragment argument. Anywhere else Ecto expands them.
  defmacro map(_source, _value), do: true
  defmacro constant(value), do: quote(do: sum(unquote(value)))
end

defmodule Mutare.Ecto.DslAuditProjectionMacros do
  @moduledoc false
  # `map/2` inside an ordinary expression is no select grammar: Ecto expands it.
  defmacro map(_source, value), do: quote(do: sum(unquote(value)))
end

defmodule Mutare.Ecto.DslAuditBindingMacros do
  @moduledoc false
  # Ecto's binding names are its own only as a field's receiver (`as(:p).x`); standing alone,
  # Ecto expands a same-named macro.
  defmacro as(_condition), do: true
  defmacro parent_as(_condition), do: true
end

defmodule Mutare.Ecto.DslAuditDiscardMacros do
  @moduledoc false
  # Macros whose expansion drops their argument, aggregate and all. `map/2` over a non-variable
  # is no select take, so Ecto expands it.
  defmacro discard(_expression), do: 0
  defmacro map(_source, _fields), do: 0
end

defmodule Mutare.Ecto.DslAuditRemoteMacros do
  @moduledoc false
  # Called remotely, so never Ecto's window grammar: Ecto expands every remote call.
  defmacro over(value, options),
    do: quote(do: coalesce(unquote(value), unquote(Keyword.fetch!(options, :fallback))))
end

defmodule Mutare.Ecto.DslAuditWindowMacros do
  @moduledoc false
  # A window's function is Ecto's only if `Ecto.Query.WindowAPI` names it; Ecto expands any
  # other call there, even one of its own expression names.
  defmacro coalesce(_left, _right), do: quote(do: row_number())
end

defmodule Mutare.Ecto.DslAuditTypeMacros do
  @moduledoc false
  # `type/2` takes only the operand forms its builder names; Ecto expands any other call there,
  # even one of its own expression names.
  defmacro is_nil(value), do: quote(do: sum(unquote(value)))
end

defmodule Mutare.Ecto.DslAuditTakeMacros do
  @moduledoc false
  # A select take's field list is expanded at compile time, never escaped as SQL.
  defmacro sum(_expression), do: [:views]
end

defmodule Mutare.Ecto.DslAuditTemplateMacros do
  @moduledoc false
  # A fragment's template is expanded to a string at compile time, never escaped as SQL.
  defmacro sum(_expression), do: "?"
end

defmodule Mutare.Ecto.DslAuditUnwrapMacros do
  @moduledoc false
  # Expanded in `type/2`'s operand, this discards the aggregate its argument seems to hold.
  defmacro is_nil({:sum, _meta, [field]}), do: field
end

defmodule Mutare.Ecto.DslAuditSyntaxMacros do
  @moduledoc false
  # A macro that reads its argument's syntax: it unwraps a `sum`, and keeps anything else.
  defmacro unwrap_sum({:sum, _meta, [expression]}), do: expression
  defmacro unwrap_sum(expression), do: expression
end

defmodule Mutare.Ecto.DslAuditShapeMacros do
  @moduledoc false
  # Ecto's names in shapes Ecto's heads do not take: `over` over a literal or at arity three,
  # `merge/2` outside the projection's own level. Ecto expands each.
  defmacro over(nil, _condition), do: true
  defmacro over(_first, _second, _third), do: 0
  defmacro merge({:sum, _meta, [value]}, _right), do: value
  defmacro merge(value, _right), do: value
end

defmodule Mutare.Ecto.DslAuditRegressionTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  defp fixture(body) do
    """
    defmodule AuditQuery do
      import Ecto.Query
      import Mutare.Ecto.DslAuditMacros
      alias MyApp.{Post, User}
      @first_column 1
      def next_id, do: System.unique_integer([:positive])
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

  test "a keyword-filter value in an inline subquery fills a comparison operand" do
    for predicate <- ["exists(inner)", "p.id in subquery(inner)"],
        {pair, kept} <- [
          # Ecto builds `r.value == nil` from the drop and rejects it at expansion.
          {"value: coalesce(nil, r.value)", nil},
          {"value: coalesce(r.value, 0)", {"coalesce(r.value, 0)", "r.value"}}
        ] do
      source =
        fixture("""
        from p in "outer_rows",
          where: #{String.replace(predicate, "inner", ~s|from(r in "audit_rows", where: [#{pair}], select: r.id)|)},
          select: p.id
        """)

      assert_native_builds(source)
      assert_builds(source, & &1.q(), only([:coalesce]))

      case kept do
        nil -> assert ecto_diffs(source, only([:coalesce])) == []
        {before, after_code} -> assert_rewrite(source, [:coalesce], before, after_code)
      end
    end
  end

  test "EXISTS keeps a projection mutant that removes the query's only aggregate" do
    # Over an empty table the ungrouped aggregate is one row; its drop is none.
    for {expression, coalesce, dropped} <- [
          {"coalesce(nil, sum(r.value))", "coalesce(nil, sum(r.value))", "nil"},
          {"coalesce(0, sum(r.value))", "coalesce(0, sum(r.value))", "0"},
          # A pin names fields at the `select` root, so this one sits in a map.
          {"%{n: coalesce(^override, count(r.id))}", "coalesce(^override, count(r.id))",
           "^override"}
        ] do
      source =
        fixture("""
        override = 1
        from p in "outer_rows",
          where: exists(from r in "audit_rows", select: #{expression}),
          select: p.id
        """)

      assert_native_builds(source)
      assert_rewrite(source, [:coalesce], coalesce, dropped)
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  test "EXISTS still prunes a projection mutant that keeps the query's aggregation" do
    for inner <- [
          # The kept operand is itself the aggregate.
          ~s|from r in "audit_rows", select: coalesce(sum(r.value), 0)|,
          # Another aggregate keeps the projection aggregating.
          ~s|from r in "audit_rows", select: {sum(r.a), coalesce(0, sum(r.value))}|,
          # The grouping fixes the row count.
          ~s|from r in "audit_rows", group_by: r.a, select: coalesce(0, sum(r.value))|,
          # A window's `sum` aggregates the window, not the query.
          ~s|from r in "audit_rows", select: coalesce(0, over(sum(r.value)))|
        ] do
      source =
        fixture(~s|from p in "outer_rows", where: exists(#{inner}), select: p.id|)

      assert_native_builds(source)
      assert ecto_diffs(source, only([:coalesce])) == []
    end

    # A same-arity swap keeps the aggregate.
    source =
      fixture(
        ~s|from p in "outer_rows", where: exists(from r in "audit_rows", select: sum(r.value)), select: p.id|
      )

    assert ecto_diffs(source, only([:aggregate])) == []
  end

  test "a coalesce drop never leaves a pin where Ecto reads a pin as fields" do
    for query <- [
          ~s|from p in "audit_rows", select: coalesce(^x, p.value)|,
          ~s|from p in "audit_rows", order_by: [asc: coalesce(^x, p.value)], select: p.id|,
          ~s|"audit_rows" \|> order_by([p], coalesce(^x, p.value)) \|> select([p], p.id)|,
          ~s|"audit_rows" \|> select([p], coalesce(^x, p.value))|,
          ~s|from p in "audit_rows", select: over(sum(p.value), partition_by: coalesce(^x, p.a))|
        ] do
      source = fixture("x = :value\n#{query}")
      assert ecto_diffs(source, only([:coalesce])) == []
      assert_builds(source, & &1.q(), only([:coalesce]))
    end

    # Inside a map or an operator, the pin is a value again.
    source = fixture(~s|x = 1\nfrom p in "audit_rows", select: %{v: coalesce(^x, p.value) + 1}|)
    assert_rewrite(source, [:coalesce], "coalesce(^x, p.value)", "^x")
    assert_builds(source, & &1.q(), only([:coalesce]))
  end

  describe "EXISTS judges a projection mutant by the query's aggregation" do
    defp exists_source(inner, prelude \\ "") do
      fixture("""
      #{prelude}
      from p in "outer_rows", where: exists(#{inner}), select: p.id
      """)
    end

    test "a drop whose retained operand aggregates keeps the aggregation" do
      for expression <- [
            "coalesce(min(r.a), max(r.b))",
            "coalesce(sum(r.value), count(r.id))"
          ] do
        source = exists_source(~s|from r in "audit_rows", select: #{expression}|)
        assert_native_builds(source)
        assert ecto_diffs(source, only([:coalesce])) == []
      end
    end

    test "an ordinary aggregate inside a window's operands or options aggregates the query" do
      for expression <- [
            "coalesce(0, over(sum(sum(r.value))))",
            "coalesce(0, over(lag(sum(r.value))))",
            "coalesce(0, over(row_number(), order_by: sum(r.value)))",
            "coalesce(0, over(filter(sum(r.value), count(r.id) > 0)))"
          ] do
        source = exists_source(~s|from r in "audit_rows", select: #{expression}|)
        assert_native_builds(source)
        assert_rewrite(source, [:coalesce], expression, "0")
        assert_builds(source, & &1.q(), only([:coalesce]))
      end

      # The windowed call alone aggregates the window, not the query.
      source =
        exists_source(~s|from r in "audit_rows", select: coalesce(0, over(sum(r.value)))|)

      assert ecto_diffs(source, only([:coalesce])) == []
    end

    test "the projection is judged after select_merge replaces earlier fields" do
      import Ecto.Query

      # Ecto's merge replaces the earlier `n`, so `sum(r.a)` never reaches the projection.
      merged =
        from(r in "audit_rows",
          select: %{n: sum(r.a)},
          select_merge: %{n: coalesce(0, sum(r.value))}
        )

      assert %{select: %{expr: {:%{}, _, [n: {:coalesce, _, _}]}}} = merged

      for {inner, kept?} <- [
            {~s|select: %{n: sum(r.a)}, select_merge: %{n: coalesce(0, sum(r.value))}|, true},
            # A merge whose keys cannot be read may replace `n`, so it proves nothing.
            {~s|select: %{n: sum(r.a), m: coalesce(0, sum(r.value))}, select_merge: ^extra|,
             true},
            # Under a different key the aggregate survives the merge.
            {~s|select: %{kept: sum(r.a)}, select_merge: %{n: coalesce(0, sum(r.value))}|, false},
            # A drop in a replaced field changes nothing.
            {~s|select: %{n: coalesce(0, sum(r.value))}, select_merge: %{n: sum(r.a)}|, false}
          ] do
        source = exists_source(~s|from r in "audit_rows", #{inner}|, "extra = %{}")
        assert_native_builds(source)
        assert_builds(source, & &1.q(), only([:coalesce]))

        if kept?,
          do: assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.value))", "0"),
          else: assert(ecto_diffs(source, only([:coalesce])) == [])
      end
    end

    test "a projection dynamic reaches core under EXISTS" do
      for {wrapper, projection} <- [
            {"exists", "^dynamic([r], coalesce(0, sum(r.value)))"},
            {"exists", "^%{n: dynamic([r], coalesce(0, sum(r.value)))}"},
            {"subquery", "^dynamic([r], coalesce(0, sum(r.value)))"}
          ] do
        inner = ~s|from(r in "audit_rows", select: #{projection})|

        predicate =
          if wrapper == "exists", do: "exists(#{inner})", else: "p.id in subquery(#{inner})"

        source = fixture(~s|from p in "outer_rows", where: #{predicate}, select: p.id|)
        assert_native_builds(source)
        assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.value))", "0")
        assert_builds(source, & &1.q(), only([:coalesce]))
      end
    end

    test "a windowed fragment may hide an ordinary aggregate" do
      for expression <- [
            ~s|coalesce(0, over(fragment("sum(sum(?))", r.value)))|,
            ~s|coalesce(0, fragment("sum(?)", r.value))|
          ] do
        source = exists_source(~s|from r in "audit_rows", select: #{expression}|)
        assert_native_builds(source)
        assert_rewrite(source, [:coalesce], expression, "0")
        assert_builds(source, & &1.q(), only([:coalesce]))
      end
    end

    test "a having clause does not fix the aggregation" do
      # Ecto keeps a written `having: true` or `having: []` (SQLite then rejects HAVING on the
      # mutant's non-aggregate query) and discards a pinned one at runtime (the mutant
      # projects no rows over an empty input). Either way the drop is not equivalent.
      import Ecto.Query
      truth = true

      for {clause, retained} <- [
            {"having: true", 1},
            {"or_having: []", 1},
            {"having: ^truth", 0},
            {"or_having: ^truth", 0}
          ] do
        inner = ~s|from r in "audit_rows", #{clause}, select: coalesce(0, sum(r.value))|
        {native, _binding} = Code.eval_string(inner, [truth: truth], __ENV__)
        assert length(Ecto.Queryable.to_query(native).havings) == retained

        source = exists_source(inner, "truth = true")
        assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.value))", "0")
        assert_builds(source, & &1.q(), only([:coalesce]))
      end

      # A group_by does fix it: the query is a row per group either way.
      source =
        exists_source(
          ~s|from r in "audit_rows", group_by: r.a, having: true, select: coalesce(0, sum(r.value))|
        )

      assert ecto_diffs(source, only([:coalesce])) == []
    end

    # Whether the EXISTS subquery Ecto plans for `source` projects an aggregate. Planning is
    # where a subquery's merges replace fields (`map/2` takes included), so the premise is
    # read there rather than off the built query.
    defp inner_aggregates?(source) do
      query = Ecto.Queryable.to_query(compile_native(source).q())

      {planned, _params, _cache_key} =
        Ecto.Adapter.Queryable.plan_query(:all, Ecto.Adapters.SQLite3, query)

      [%{subqueries: [subquery]}] = planned.wheres

      {_expr, found?} =
        Macro.prewalk(subquery.query.select.expr, false, fn
          {:sum, _meta, [_arg]} = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end)

      found?
    end

    test "a map update and merge/2 are folded like select_merge" do
      for {projection, kept?} <- [
            # A map update's pairs replace the fields it takes, so the base is no empty map.
            {"%{map(r, [:value]) | value: coalesce(0, sum(r.value))}", true},
            {"merge(%{n: sum(r.a)}, %{n: coalesce(0, sum(r.value))})", true},
            {"merge(%{kept: sum(r.a)}, %{n: coalesce(0, sum(r.value))})", false},
            {"%{value: coalesce(0, sum(r.value))}", true}
          ] do
        source = exists_source(~s|from r in "audit_rows", select: #{projection}|)
        assert inner_aggregates?(source)

        refute inner_aggregates?(String.replace(source, "coalesce(0, sum(r.value))", "0")) ==
                 kept?

        assert_builds(source, & &1.q(), only([:coalesce]))

        if kept?,
          do: assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.value))", "0"),
          else: assert(ecto_diffs(source, only([:coalesce])) == [])
      end
    end

    test "a projection pin that decides the aggregation reaches core" do
      # No plugin family is enabled, so only core's `true` → `false` inside the pin can pass.
      boolean_only = [
        mutators: [Mutare.Mutators.BooleanLiteral, {Mutare.Ecto, repo: MyApp.Repo, families: []}]
      ]

      for inner <- [
            # The whole projection, picked from dynamics built elsewhere.
            ~s|select: ^(if true, do: aggregate, else: plain)|,
            # A merge key that replaces the aggregate or leaves it.
            ~s|select: %{n: sum(r.value)}, select_merge: %{^(if true, do: :n, else: :other) => 0}|,
            # A take's field list that replaces the aggregate or leaves it.
            ~s|select: %{value: sum(r.value)}, select_merge: map(r, ^(if true, do: [:value], else: [:id]))|
          ] do
        source =
          exists_source(
            ~s|from r in "audit_rows", #{inner}|,
            "aggregate = dynamic([r], sum(r.value))\nplain = dynamic(0)"
          )

        assert inner_aggregates?(source) !=
                 inner_aggregates?(String.replace(source, "if true", "if false"))

        diffs = diffs(source, boolean_only)
        assert {:boolean, "true", "false"} in diffs, "got #{inspect(diffs)}"
        assert_builds(source, & &1.q(), boolean_only)
      end
    end

    test "a query parameter in the projection stays out of core's reach under EXISTS" do
      arithmetic_only = [
        mutators: [Mutare.Mutators.Arithmetic, {Mutare.Ecto, repo: MyApp.Repo, families: []}]
      ]

      for projection <- [
            "%{n: ^(bump + 1)}",
            "{r.value, ^(bump + 1)}",
            "sum(r.value + ^(bump + 1))"
          ] do
        inner = ~s|from r in "audit_rows", select: #{projection}|
        assert diffs(exists_source(inner, "bump = 1"), arithmetic_only) == []

        # The same parameter is observed where the wrapper reads projected values.
        value_source =
          fixture(
            ~s|bump = 1\nfrom p in "outer_rows", where: p.id in subquery(#{inner}), select: p.id|
          )

        assert diffs(value_source, arithmetic_only) != []
      end
    end

    test "a clause may read a projection alias through a pin or a fragment" do
      select = "select: selected_as(r.a + r.b, :bucket)"

      for {reader, kept?} <- [
            {"group_by: ^grouping", true},
            {~s|group_by: fragment("bucket")|, true},
            {"having: ^condition", true},
            {"group_by: selected_as(:bucket)", true},
            # An unregistered macro Ecto expands (`selected_as(:n) > 1`, aliased as `:bucket`).
            {"where: positive_alias()", true},
            # A parameter inside a condition is no dynamic.
            {"where: r.a > ^floor", false},
            {"group_by: r.a", false}
          ] do
        source =
          exists_source(
            ~s|from r in "rows", #{reader}, limit: 10, offset: 1, #{select}|,
            "grouping = [dynamic(selected_as(:bucket))]\n" <>
              "condition = dynamic(selected_as(:bucket) > 0)\nfloor = 0"
          )

        assert_builds(source, & &1.q(), only([:arithmetic]))

        if kept?,
          do: assert_rewrite(source, [:arithmetic], "r.a + r.b", "r.a - r.b"),
          else: assert(ecto_diffs(source, only([:arithmetic])) == [])
      end

      # Without an alias to read, and with no offset or having for a positional term to matter
      # in, a pinned grouping reads nothing that changes existence.
      source =
        exists_source(
          ~s|from r in "rows", group_by: ^grouping, select: r.a + r.b|,
          "grouping = [dynamic([r], r.a)]"
        )

      assert ecto_diffs(source, only([:arithmetic])) == []
    end

    test "a grouping by projected position observes the projection" do
      for {clauses, kept?} <- [
            {"group_by: 1, limit: 10, offset: 1", true},
            {~s|group_by: fragment("1"), limit: 10, offset: 1|, true},
            {"group_by: ^grouping, limit: 10, offset: 1", true},
            {"group_by: 1, having: count(r.a) > 1", true},
            {"distinct: 1, limit: 10, offset: 1", true},
            # Ecto expands a module attribute or a macro in a grouping term.
            {"group_by: @first_column, limit: 10, offset: 1", true},
            # The number of groups decides nothing without an offset or a having.
            {"group_by: 1", false},
            {"group_by: r.a, limit: 10, offset: 1", false}
          ] do
        source =
          exists_source(
            ~s|from r in "rows", #{clauses}, select: r.a + r.b|,
            "grouping = [dynamic(1)]"
          )

        assert_builds(source, & &1.q(), only([:arithmetic]))

        if kept?,
          do: assert_rewrite(source, [:arithmetic], "r.a + r.b", "r.a - r.b"),
          else: assert(ecto_diffs(source, only([:arithmetic])) == [])
      end
    end

    test "group_by: nil groups nothing" do
      for grouping <- ["nil", "[]", "@empty", "^empty"] do
        source =
          exists_source(
            ~s|from r in "rows", group_by: #{grouping}, select: coalesce(0, sum(r.value))|,
            "empty = []"
          )
          |> String.replace("@first_column 1", "@first_column 1\n  @empty []")

        assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.value))", "0")
        assert_builds(source, & &1.q(), only([:coalesce]))
      end
    end

    test "an unregistered macro may hide the projection's aggregate" do
      # `sum/2` is not Ecto's `sum/1`: Ecto expands it.
      for aggregate <- ["total(r.value)", "sum(r.x, r.y)", "constant(r.x)"] do
        source = exists_source(~s|from r in "rows", select: coalesce(0, #{aggregate})|)
        assert_rewrite(source, [:coalesce], "coalesce(0, #{aggregate})", "0")
        assert_builds(source, & &1.q(), only([:coalesce]))
      end
    end

    test "a named window's aggregate is read at each use of the window" do
      for {windows, projection, kept?} <- [
            # Inline and named spell the same window.
            {"", "coalesce(0, over(row_number(), order_by: sum(r.value)))", true},
            {"windows: [w: [order_by: sum(r.value)]],", "coalesce(0, over(row_number(), :w))",
             true},
            # A pinned window option may be an aggregate.
            {"windows: [w: [order_by: ^order]],", "coalesce(0, over(row_number(), :w))", true},
            # A window with no aggregate, inline or named, aggregates nothing.
            {"", "coalesce(0, over(row_number(), order_by: r.value))", false},
            {"windows: [w: [order_by: r.value]],", "coalesce(0, over(row_number(), :w))", false},
            # Another use of `:w` keeps the query aggregating after the drop.
            {"windows: [w: [order_by: sum(r.value)]],",
             "%{changed: coalesce(0, over(row_number(), :w)), retained: over(row_number(), :w)}",
             false}
          ] do
        source =
          exists_source(
            ~s|from r in "rows", #{windows} select: #{projection}|,
            "order = [asc: dynamic([r], sum(r.value))]"
          )

        assert_builds(source, & &1.q(), only([:coalesce]))

        if kept?,
          do: assert_rewrite(source, [:coalesce], "coalesce(0, over(row_number(), ", "0"),
          else: assert(ecto_diffs(source, only([:coalesce])) == [])
      end
    end

    test "a select-only name nested in a projection expression is a macro" do
      source =
        """
        defmodule AuditQuery do
          import Ecto.Query
          import Mutare.Ecto.DslAuditProjectionMacros
          def q do
            from p in "outer_rows",
              where: exists(from r in "rows", select: coalesce(0, map(r, r.value))),
              select: p.id
          end
        end
        """

      assert_rewrite(source, [:coalesce], "coalesce(0, map(r, r.value))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))

      # At the projection's own grammar level, `map/2` is Ecto's take and hides nothing.
      source = exists_source(~s|from r in "rows", select: {map(r, [:value]), coalesce(0, 1)}|)
      assert ecto_diffs(source, only([:coalesce])) == []
    end

    test "an unregistered macro in the projection may define the alias a clause reads" do
      source =
        exists_source(
          ~s|from r in "rows", where: fragment("bucket > 0"), select: aliased(r.x + r.y)|
        )

      assert_rewrite(source, [:arithmetic], "r.x + r.y", "r.x - r.y")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end

    test "an aggregate over only an enclosing query's columns is not this query's" do
      source =
        fixture("""
        from o in "outer_rows", as: :outer,
          having: exists(from r in "rows", where: r.x > 10,
            select: coalesce(0, sum(r.x)) + max(parent_as(:outer).x)),
          select: max(o.x)
        """)

      assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.x))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end

    test "a having that may read a bare column observes the aggregate swap" do
      for {clauses, kept?} <- [
            {"having: r.y == 1", true},
            {"group_by: r.z, having: r.y == 1", true},
            {"having: ^condition", true},
            {~s|having: fragment("y = 1")|, true},
            {"having: [y: 1]", true},
            # Only aggregated or grouped columns: the aggregate picks no row for the `having`.
            {"having: sum(r.y) > 1", false},
            {"group_by: r.y, having: r.y == 1", false},
            {"having: filter(count(r.id), r.y == 1) > 0", false}
          ] do
        source =
          exists_source(
            ~s|from r in "rows", #{clauses}, select: min(r.x)|,
            "condition = dynamic([r], r.y == 1)"
          )

        assert_builds(source, & &1.q(), only([:aggregate]))

        if kept?,
          do: assert_rewrite(source, [:aggregate], "min(r.x)", "max(r.x)"),
          # The `having`'s own aggregates are still its catalog's.
          else:
            refute(
              Enum.any?(ecto_diffs(source, only([:aggregate])), &(elem(&1, 0) == "min(r.x)"))
            )
      end
    end
  end

  test "a filter that is or may become the literal true is rebuilt, never woven" do
    for {clauses, family} <- [
          {"where: false, or_where: true", :boolean_literal},
          {"where: true, or_where: r.a > 1", :boolean_literal},
          {"group_by: r.a, having: false, or_having: true", :boolean_literal},
          {"where: false, or_where: coalesce(true, false)", :coalesce},
          # Ecto's escape erases `filter/1`, and expands a macro, into the literal `true`.
          {"where: false, or_where: filter(true)", :boolean_literal},
          {"where: false, or_where: ignore(r.a > 1)", :comparison},
          {"where: false, or_where: coalesce(true)", :boolean_literal},
          # Ecto's fragment heads take at least the query, so it expands `fragment()`.
          {"where: false, or_where: coalesce(fragment(), false)", :coalesce},
          {"where: false, or_where: map(r.a, 1)", :integer_literal}
        ] do
      source = fixture(~s|from r in "rows", #{clauses}, select: r.a|)
      assert ecto_diffs(source, only([family])) != []
      assert_builds(source, & &1.q(), only([family]))
      # Ecto's runtime filter path would drop a woven `true`.
      refute metamutant(source, only([family])) =~ "dynamic("
    end

    # Any other condition still weaves.
    source = fixture(~s|from r in "rows", where: false, or_where: r.a > 1, select: r.a|)
    assert metamutant(source, only([:comparison])) =~ "dynamic("
  end

  test "a condition whose pin or literal takes the clause's type is rebuilt, never woven" do
    for {condition, rebuilt?} <- [
          {~s|coalesce(^flag, false)|, true},
          {"coalesce(r.flag, 1)", true},
          {"coalesce(r.flag, -(^n))", true},
          # `count(x, :distinct)` and `filter`'s aggregate pass it on too.
          {"count(r.a / ^n, :distinct)", true},
          {"filter(count(r.a / ^n, :distinct), r.a > 0)", true},
          # A string sigil is a literal to Ecto.
          {"coalesce(~s(0.5), false)", true},
          {"coalesce(~S(0.5), false)", true},
          {"count(r.a / ^n)", false},
          {"coalesce(r.flag, false)", false},
          {"r.a > ^n", false},
          {"r.flag and ^flag", false},
          {"not coalesce(^flag, false)", false}
        ] do
      source =
        fixture(~s|flag = true\nn = 1\nfrom r in "rows", where: #{condition}, select: r.a|)

      families =
        only([
          :boolean_literal,
          :integer_literal,
          :coalesce,
          :comparison,
          :connective,
          :arithmetic
        ])

      assert_builds(source, & &1.q(), families)
      assert metamutant(source, families) =~ "dynamic(" != rebuilt?
    end
  end

  describe "a keyword filter pair's value" do
    # Interpolating a pair value sends it through its column type's `cast/1`, where the written
    # literal is only `dump/1`ed; a custom type's `cast/1` may change it.
    defp label_source(query) do
      """
      defmodule LabelQuery do
        import Ecto.Query
        alias MyApp.Label, as: L
        def q do
          #{query}
        end
      end
      """
    end

    defp string_only, do: [mutators: [Mutare.Mutators.StringLiteral, {Mutare.Ecto, families: []}]]

    defp mutated_values(source) do
      for {_producer, original, _mutated} <- diffs(source, string_only()),
          into: MapSet.new(),
          do: original
    end

    test "is mutated only where the column's type keeps the literal it is cast from" do
      for query <- [
            ~s|from l in L, where: [plain: "UP", folded: "DOWN"]|,
            ~s|from l in :"Elixir.MyApp.Label", where: [plain: "UP", folded: "DOWN"]|,
            ~s|from l in "labels", join: m in L, on: [plain: "UP", folded: "DOWN"]|,
            ~s|where(L, plain: "UP", folded: "DOWN")|,
            ~s{L |> where([l], plain: "UP", folded: "DOWN")},
            ~s|join("labels", :inner, [x], m in L, on: [plain: "UP", folded: "DOWN"])|
          ] do
        source = label_source(query)
        assert mutated_values(source) == MapSet.new([~s|"UP"|]), query
        assert_builds(source, & &1.q(), string_only())
      end
    end

    test "keeps its written value at baseline" do
      source = label_source(~s|from l in L, where: [plain: "UP", folded: "UP"]|)
      {[module], _sites} = Mutare.Test.compile_metamutant(source, mutators(string_only()))
      baseline = Mutare.Test.with_active_mutant(0, fn -> module.q() end)
      native = compile_native(source).q()

      plan = &Ecto.Adapter.Queryable.plan_query(:all, Ecto.Adapters.SQLite3, &1)
      {_planned, native_params, _key} = plan.(native)
      {_planned, baseline_params, _key} = plan.(baseline)
      assert native_params == []
      # `plain` is pinned for its mutants, `folded` stays the written literal.
      assert baseline_params == ["UP"]
    end

    test "is left alone for a parameterized or binary_id column" do
      for {pair, value} <- [{"status: :active", ":active"}, {~s|uid: "ABC"|, ~s|"ABC"|}] do
        source = label_source(~s|from l in L, where: [#{pair}]|)

        opts = [
          mutators: [
            Mutare.Mutators.StringLiteral,
            Mutare.Mutators.AtomLiteral,
            {Mutare.Ecto, families: []}
          ]
        ]

        refute Enum.any?(diffs(source, opts), &(elem(&1, 1) == value))
      end
    end

    test "is still mutated on a schemaless source or one the plugin cannot read" do
      for query <- [
            ~s|from l in "labels", where: [folded: "UP"]|,
            ~s|where(q, folded: "UP")|
          ] do
        source = label_source("q = from(l in L)\n#{query}")
        assert Enum.any?(diffs(source, string_only()), &(elem(&1, 1) == ~s|"UP"|))
      end
    end
  end

  test "over/1 and over/2 observe their window function alike beneath is_nil" do
    diffs_for = fn window ->
      source = fixture(~s|dynamic([r], is_nil(#{window}))|)

      for {original, mutated} <- ecto_diffs(source, only([:aggregate])),
          into: MapSet.new(),
          do: {String.replace(original, ", []", ""), String.replace(mutated, ", []", "")}
    end

    # `sum` and `avg` over one frame are NULL on the same rows, so the swap is pruned in both.
    assert diffs_for.("over(sum(r.value))") == MapSet.new()
    assert diffs_for.("over(sum(r.value), [])") == MapSet.new()
  end

  test "a binary literal's segments are never mutated" do
    for clauses <- [
          "where: r.value == <<0>>",
          "where: r.value == <<0::utf8>>",
          "select: <<0>>",
          "order_by: fragment(\"?\", <<0>>)"
        ] do
      source = fixture(~s|from r in "rows", #{clauses}|)
      assert ecto_diffs(source, only([:integer_literal])) == []
      assert_compiles(source, only([:integer_literal]))
    end
  end

  test "a remote over/2 is an author macro, never window grammar" do
    source =
      fixture("""
      require Mutare.Ecto.DslAuditRemoteMacros
      from r in "rows", select: Mutare.Ecto.DslAuditRemoteMacros.over(r.x + 1, fallback: 1)
      """)

    assert {"r.x + 1", "r.x - 1"} in ecto_diffs(source, only([:arithmetic]))
    assert_builds(source, & &1.q(), only([:arithmetic]))
  end

  test "an author's like/1 is not swapped to a nonexistent ilike/1" do
    source = fixture(~s|from r in "rows", where: like(r.name), select: r.name|)

    opts = [
      mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:membership], dialects: [:postgres]}]
    ]

    assert ecto_diffs(source, opts) == []
    assert_builds(source, & &1.q(), opts)

    # Ecto's own like/2 still swaps.
    source = fixture(~s|from r in "rows", where: like(r.name, "a%"), select: r.name|)
    assert {~s|like(r.name, "a%")|, ~s|ilike(r.name, "a%")|} in ecto_diffs(source, opts)
  end

  test "a standalone as/1 or parent_as/1 is a macro that may expand to true" do
    for name <- ["as", "parent_as"] do
      source = """
      defmodule BindingQuery do
        import Ecto.Query
        import Mutare.Ecto.DslAuditBindingMacros
        def q, do: from(u in "users", where: false, or_where: #{name}(u.id > 0), select: u.id)
      end
      """

      assert ecto_diffs(source, only([:comparison])) != []
      assert_builds(source, & &1.q(), only([:comparison]))
      refute metamutant(source, only([:comparison])) =~ "dynamic("
    end

    # As a field's receiver, `as/1` is Ecto's named binding.
    source =
      fixture(~s|from(u in "users", as: :u, where: false, or_where: as(:u).id > 0, select: u.id)|)

    assert metamutant(source, only([:comparison])) =~ "dynamic("
  end

  test "an aggregate in a macro's argument is not a certain one" do
    for expression <- ["discard(sum(r.views))", "map(sum(r.views), [])"] do
      source = """
      defmodule DiscardQuery do
        import Ecto.Query
        import Mutare.Ecto.DslAuditDiscardMacros
        def q do
          from u in "users",
            where: exists(from r in "posts", where: false,
              select: %{a: #{expression}, b: coalesce(0, sum(r.views))}),
            select: u.id
        end
      end
      """

      assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.views))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  test "a value subquery's ordering is observed when its source may bring the limit" do
    ordering = [mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:ordering]}]]

    for {prelude, source_query, kept?} <- [
          {~s|base = from r in "rows", limit: 1|, "base", true},
          {"", ~s|"rows"|, false}
        ] do
      source =
        fixture("""
        #{prelude}
        from p in "outer_rows",
          where: p.id == subquery(from r in #{source_query}, order_by: [asc: r.id], select: r.id),
          select: p.id
        """)

      assert_builds(source, & &1.q(), ordering)
      assert ecto_diffs(source, ordering) != [] == kept?
    end
  end

  describe "a window's function in its own grammar" do
    defp window_fixture(body) do
      """
      defmodule WindowQuery do
        import Ecto.Query
        import Mutare.Ecto.DslAuditWindowMacros
        def q do
          #{body}
        end
      end
      """
    end

    test "is an author macro, never mutated, unless Ecto.Query.WindowAPI names it" do
      for window <- ["over(coalesce(0, 0))", "over(coalesce(0, 0), partition_by: r.a)"] do
        source = window_fixture(~s|from r in "rows", select: #{window}|)
        assert_native_builds(source)
        assert ecto_diffs(source, only([:coalesce, :integer_literal])) == []
        assert_builds(source, & &1.q(), only([:coalesce, :integer_literal]))
      end
    end

    test "hides whatever aggregate its arguments seem to hold" do
      source =
        window_fixture("""
        from u in "users",
          where: exists(from r in "posts",
            select: coalesce(0, sum(r.views)) + over(coalesce(sum(r.views), 0))),
          select: u.id
        """)

      assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.views))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  describe "type/2's operand in its own grammar" do
    defp type_fixture(body) do
      """
      defmodule TypeQuery do
        import Kernel, except: [is_nil: 1]
        import Ecto.Query
        import Mutare.Ecto.DslAuditTypeMacros
        alias MyApp.{Post, User}
        def q do
          #{body}
        end
      end
      """
    end

    test "is an author macro, never mutated, unless type/2 names its form" do
      source =
        type_fixture("""
        from p in Post, having: type(is_nil(p.views), :integer) > 0, select: sum(p.views)
        """)

      assert_native_builds(source)
      assert ecto_diffs(source, only([:null_predicate])) == []
      assert_builds(source, & &1.q(), only([:null_predicate, :comparison]))
    end

    test "hides whatever aggregate it expands to" do
      source =
        type_fixture("""
        from u in User,
          where: exists(from p in Post, where: false,
            select: coalesce(0, type(is_nil(p.views), :integer))),
          select: u.id
        """)

      assert_rewrite(source, [:coalesce], "coalesce(0, type(is_nil(p.views), :integer))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  describe "a select take's field list" do
    defp take_fixture(body) do
      """
      defmodule TakeQuery do
        import Ecto.Query
        import Mutare.Ecto.DslAuditTakeMacros
        alias MyApp.{Post, User}
        def q do
          #{body}
        end
      end
      """
    end

    test "is never mutated as SQL" do
      for take <- ["map", "struct"] do
        source = take_fixture("from p in Post, select: #{take}(p, sum(p.views))")
        assert_native_builds(source)
        assert ecto_diffs(source, only([:aggregate])) == []
        assert_builds(source, & &1.q(), only([:aggregate]))
      end
    end

    test "holds no aggregate" do
      source =
        take_fixture("""
        from u in User,
          where: exists(from p in Post, where: false,
            select: %{a: map(p, sum(p.views)), b: coalesce(0, sum(p.views))}),
          select: u.id
        """)

      assert_rewrite(source, [:coalesce], "coalesce(0, sum(p.views))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  test "a fragment's template is never mutated as SQL" do
    source = """
    defmodule TemplateQuery do
      import Ecto.Query
      import Mutare.Ecto.DslAuditTemplateMacros
      def q, do: from(r in "rows", where: fragment(sum(r.x), r.x) > 0, select: r.x)
    end
    """

    assert_native_builds(source)
    assert ecto_diffs(source, only([:aggregate])) == []
    assert_builds(source, & &1.q(), only([:aggregate, :comparison]))
  end

  test "EXISTS reads a having's type/2 operand as possibly a bare column" do
    source = """
    defmodule UnwrapQuery do
      import Kernel, except: [is_nil: 1]
      import Ecto.Query
      import Mutare.Ecto.DslAuditUnwrapMacros
      def q do
        from o in "rows",
          where: exists(from r in "rows",
            having: type(is_nil(sum(r.y)), :integer) == 1,
            select: min(r.x)),
          select: o.x
      end
    end
    """

    assert_rewrite(source, [:aggregate], "min(r.x)", "max(r.x)")
    assert_builds(source, & &1.q(), only([:aggregate]))
  end

  test "EXISTS reads a positional grouping through filter/1" do
    source =
      fixture("""
      from o in "rows",
        where: exists(from r in "rows",
          group_by: filter(1), limit: 10, offset: 1,
          select: r.x + r.y),
        select: o.x
      """)

    assert_rewrite(source, [:arithmetic], "r.x + r.y", "r.x - r.y")
    assert_builds(source, & &1.q(), only([:arithmetic]))
  end

  test "EXISTS keeps an aggregate swap an enclosing macro may read" do
    source = """
    defmodule UnwrapSumQuery do
      import Ecto.Query
      import Mutare.Ecto.DslAuditSyntaxMacros
      def q do
        from p in "rows",
          where: exists(from r in "rows", where: r.id < 0, select: unwrap_sum(sum(r.id))),
          select: p.id
      end
    end
    """

    assert_rewrite(source, [:aggregate], "sum(r.id)", "avg(r.id)")
    assert_builds(source, & &1.q(), only([:aggregate]))
  end

  describe "an over or merge in a shape Ecto's heads do not take" do
    defp shape_fixture(body) do
      """
      defmodule ShapeQuery do
        import Ecto.Query
        import Mutare.Ecto.DslAuditShapeMacros
        def q do
          #{body}
        end
      end
      """
    end

    test "over a literal is a macro that may expand to true" do
      source =
        shape_fixture(
          ~s|from r in "rows", where: false, or_where: over(nil, r.id > 0), select: r.id|
        )

      assert ecto_diffs(source, only([:comparison])) != []
      assert_builds(source, & &1.q(), only([:comparison]))
      refute metamutant(source, only([:comparison])) =~ "dynamic("
    end

    test "over/3 holds no certain aggregate" do
      source =
        shape_fixture("""
        from o in "rows",
          where: exists(from r in "rows", where: r.id < 0,
            select: %{a: over(0, sum(r.id), 0), b: coalesce(0, sum(r.id))}),
          select: o.id
        """)

      assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.id))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end

    test "merge/2 inside an expression is a macro that may read an aggregate's syntax" do
      source =
        shape_fixture("""
        from o in "rows",
          where: exists(from r in "rows", where: r.id < 0,
            select: coalesce(merge(sum(r.id), %{}), 0)),
          select: o.id
        """)

      assert_rewrite(source, [:aggregate], "sum(r.id)", "avg(r.id)")
      assert_builds(source, & &1.q(), only([:aggregate]))
    end
  end

  test "EXISTS reads a projection fragment as possibly defining an alias" do
    source =
      fixture(~S"""
      from o in "rows",
        where: exists(from r in "rows",
          where: fragment("n > 1"),
          select: fragment("? AS n", r.x + 1)),
        select: o.x
      """)

    assert_rewrite(source, [:arithmetic], "r.x + 1", "r.x - 1")
    assert_builds(source, & &1.q(), only([:arithmetic]))
  end

  test "EXISTS counts an aggregate in a fragment's argument as uncertain" do
    source =
      fixture(~S"""
      from o in "rows",
        where: exists(from r in "rows",
          select: %{a: coalesce(0, sum(r.x)), b: fragment("? OVER ()", count())}),
        select: o.x
      """)

    assert_rewrite(source, [:coalesce], "coalesce(0, sum(r.x))", "0")
    assert_builds(source, & &1.q(), only([:coalesce]))
  end

  test "an ordering mutant that changes whether the query aggregates is observed without a window" do
    for condition <- [
          ~s|exists(from r in "rows", select: 1, order_by: coalesce(1, sum(r.x)))|,
          ~s|o.x in subquery(from r in "rows", select: 1, order_by: coalesce(1, sum(r.x)))|
        ] do
      source = fixture(~s|from o in "rows", where: #{condition}, select: o.x|)
      assert_rewrite(source, [:coalesce], "coalesce(1, sum(r.x))", "1")
      assert_builds(source, & &1.q(), only([:coalesce, :aggregate, :ordering]))
    end

    # One that keeps the aggregation, or only flips a direction, is not.
    for ordering <- ["[desc: sum(r.x)]", "coalesce(1, sum(r.x)) + sum(r.x)"] do
      source =
        fixture("""
        from o in "rows",
          where: exists(from r in "rows", select: 1, order_by: #{ordering}),
          select: o.x
        """)

      assert ecto_diffs(source, only([:coalesce, :aggregate, :ordering, :arithmetic])) == []
    end
  end

  test "an in-list drops each occurrence of an element that may evaluate differently alone" do
    membership = only([:membership])

    source = fixture(~s|from r in "rows", where: r.id in [^next_id(), ^next_id()], select: r.id|)

    assert {"r.id in [^next_id(), ^next_id()]", "r.id in [^next_id()]"} in ecto_diffs(
             source,
             membership
           )

    assert_builds(source, & &1.q(), membership)

    # A zero-argument remote call has a field access's shape, but is a call.
    source =
      fixture(
        ~s|from r in "rows", where: r.id in [^Counter.next(), ^Counter.next()], select: r.id|
      )

    assert {"r.id in [^Counter.next(), ^Counter.next()]", "r.id in [^Counter.next()]"} in ecto_diffs(
             source,
             membership
           )

    # A module held in a variable dispatches at runtime, with or without arguments, and a key
    # read may dispatch to a struct's `fetch/2`.
    for call <- ["provider.next()", "provider.next(:token)", "provider.next", "provider[:id]"] do
      members = "[^#{call}, ^#{call}, ^3]"

      source =
        fixture(
          ~s|provider = MyApp.Post\nfrom r in "rows", where: r.id in #{members}, select: r.id|
        )

      assert {"r.id in #{members}", "r.id in [^#{call}, ^3]"} in ecto_diffs(source, membership)
    end

    # A bare pinned variable may hold a `dynamic`, which Ecto expands at each occurrence.
    source = fixture(~s|x = 1\nfrom r in "rows", where: r.id in [^x, ^x, 2], select: r.id|)
    assert {"r.id in [^x, ^x, 2]", "r.id in [^x, 2]"} in ecto_diffs(source, membership)

    # Repeated occurrences of a value that cannot change drop together.
    for member <- ["^@first_column", "^{x, 2}", "r.id + 1"] do
      source =
        fixture(
          ~s|x = 1\nopts = %{id: 1}\nfrom r in "rows", where: r.id in [#{member}, #{member}, 2], select: r.id|
        )

      refute {"r.id in [#{member}, #{member}, 2]", "r.id in [#{member}, 2]"} in ecto_diffs(
               source,
               membership
             )

      assert {"r.id in [#{member}, #{member}, 2]", "r.id in [2]"} in ecto_diffs(
               source,
               membership
             )
    end
  end

  test "an ordering aggregate may pick the row a SQLite bare column reads" do
    for {condition, kept?} <- [
          {~s|o.y in subquery(from r in "rows", select: coalesce(r.y, count()), order_by: min(r.x))|,
           true},
          {~s|exists(from r in "rows", having: r.y == 1, select: count(), order_by: min(r.x))|,
           true},
          # Nothing observes a bare column here.
          {~s|o.y in subquery(from r in "rows", select: count(), order_by: min(r.x))|, false}
        ] do
      source = fixture(~s|from o in "rows", where: #{condition}, select: o.y|)
      assert {"min(r.x)", "max(r.x)"} in ecto_diffs(source, only([:aggregate])) == kept?
      assert_builds(source, & &1.q(), only([:aggregate]))
    end
  end

  test "EXISTS reads an explicit-tuple keyword having as possibly naming a bare column" do
    source =
      fixture(~S"""
      from o in "rows",
        where: exists(from r in "rows", having: [{:name, "Carol"}], select: min(r.age)),
        select: o.id
      """)

    assert_rewrite(source, [:aggregate], "min(r.age)", "max(r.age)")
    assert_builds(source, & &1.q(), only([:aggregate]))
  end

  test "a named window is read from its definition in either pair spelling" do
    for windows <- ["[w: [order_by: sum(r.views)]]", "[{:w, [order_by: sum(r.views)]}]"] do
      source =
        fixture("""
        from p in "posts",
          where: exists(from r in "posts", where: r.id < 0, windows: #{windows},
            select: coalesce(0, over(row_number(), :w))),
          select: p.id
        """)

      assert_rewrite(source, [:coalesce], "coalesce(0, over(row_number(), :w))", "0")
      assert_builds(source, & &1.q(), only([:coalesce]))
    end
  end

  test "a DISTINCT ON pair observes a positional projection read in either spelling" do
    for distinct <- ["[asc: 1]", "[{:asc, 1}]"] do
      source =
        fixture("""
        from p in "posts",
          where: exists(from r in "posts", distinct: #{distinct}, select: r.views - r.views,
            offset: 1),
          select: p.id
        """)

      assert_rewrite(source, [:arithmetic], "r.views - r.views", "r.views + r.views")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "a window option is walked in either pair spelling" do
    for option <- ["partition_by: p.views + p.id", "{:partition_by, p.views + p.id}"] do
      source = fixture(~s|from p in "posts", select: over(sum(p.id), [#{option}])|)

      assert_rewrite(source, [:arithmetic], "p.views + p.id", "p.views - p.id")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "a window sort pair is walked in either spelling, inside a dynamic too" do
    for entry <- ["asc: p.views + p.id", "{:asc, p.views + p.id}"] do
      source =
        fixture("""
        value = dynamic([p], over(sum(p.id), order_by: [#{entry}]))
        from p in "posts", select: ^value
        """)

      assert_rewrite(source, [:arithmetic], "p.views + p.id", "p.views - p.id")
      assert_builds(source, & &1.q(), only([:arithmetic]))
    end
  end

  test "an explicit-tuple ordering flips its direction in its own spelling" do
    for query <- [
          ~s|from p in "posts", order_by: [{:asc, p.views}], select: p.id|,
          ~s/"posts" |> order_by([p], [{:asc_nulls_first, p.views}]) |> select([p], p.id)/
        ] do
      source = fixture(query)

      assert_rewrite(source, [:ordering], "{:asc", "{:desc")
      assert_builds(source, & &1.q(), only([:ordering, :ordering_nulls]))
    end

    source = fixture(~s|from p in "posts", order_by: [{:asc_nulls_first, p.views}], select: p.id|)
    assert_rewrite(source, [:ordering_nulls], "{:asc_nulls_first", "{:asc_nulls_last")
  end

  test "each ago/2 or from_now/2 occurrence in an in-list reads the clock and drops alone" do
    for helper <- ["ago", "from_now"] do
      element = ~s|#{helper}(0, "second")|

      source =
        fixture("""
        from p in "posts",
          where: type(p.inserted_at, :utc_datetime_usec) in [#{element}, ^DateTime.utc_now(), #{element}],
          select: p.id
        """)

      replacements = Enum.map(ecto_diffs(source, only([:membership])), &elem(&1, 1))
      assert Enum.any?(replacements, &(&1 =~ "[^DateTime.utc_now(), #{element}]"))
      assert Enum.any?(replacements, &(&1 =~ "[#{element}, ^DateTime.utc_now()]"))
      refute Enum.any?(replacements, &(&1 =~ "in [^DateTime.utc_now()]"))
      assert_builds(source, & &1.q(), only([:membership]))
    end
  end

  test "a dynamic select map's keys name fields, whether written or pinned" do
    mutators = [
      mutators: [
        Mutare.Mutators.AtomLiteral,
        {Mutare.Ecto, repo: MyApp.Repo, families: [:atom_literal, :string_literal]}
      ]
    ]

    for map <- [
          ~s|%{p \| title: "Changed"}|,
          ~s|%{p \| ^:title => "Changed"}|,
          ~s|%{title: p.title, note: "Changed"}|,
          ~s|%{^:title => p.title, note: "Changed"}|
        ] do
      source =
        fixture("""
        projection = dynamic([p], #{map})
        from p in MyApp.Post, select: ^projection
        """)

      # The fixture's own `next_id/0` carries `[:positive]`, which core mutates.
      mutated =
        for {_family, original, mutated} <- diffs(source, mutators),
            original != ":positive",
            do: mutated

      assert ~s|""| in mutated
      refute Enum.any?(mutated, &(&1 =~ "mutare:" or &1 =~ ":mutare"))
      assert_builds(source, & &1.q(), mutators)
    end
  end

  test "a dynamic select map's value is data, a pair inside it included" do
    mutators = [
      mutators: [Mutare.Mutators.AtomLiteral, {Mutare.Ecto, families: [:integer_literal]}]
    ]

    for map <- [
          "%{pair: {11, 22}}",
          "%{p | title: {11, 22}}",
          "%{pair: {^:left, 22}, other: 11}"
        ] do
      source =
        fixture("""
        projection = dynamic([p], #{map})
        from p in "posts", select: ^projection
        """)

      originals = for {_family, original, _mutated} <- diffs(source, mutators), do: original
      assert "11" in originals
      assert "22" in originals
      if map =~ ":left", do: assert(":left" in originals)
      assert_builds(source, & &1.q(), mutators)
    end
  end

  test "a repeated pinned variable in an in-list drops alone, as it may hold a dynamic" do
    source =
      fixture("""
      random = dynamic(fragment("abs(random() % 2)"))
      condition = dynamic([p], p.id in [^random, ^random])
      from p in "posts", where: ^condition, select: p.id
      """)

    assert_rewrite(source, [:membership], "p.id in [^random, ^random]", "p.id in [^random]")
    assert_builds(source, & &1.q(), only([:membership]))
  end

  test "a pin inside a compound cast type is an island that holds the type's names" do
    mutators = [
      mutators: [
        Mutare.Mutators.Logical,
        Mutare.Mutators.AtomLiteral,
        {Mutare.Ecto, families: []}
      ]
    ]

    for spec <- [
          "{:array, ^(if not flag, do: :integer, else: :string)}",
          "{:map, {:array, ^(if not flag, do: :integer, else: :string)}}"
        ] do
      source =
        fixture("""
        flag = System.get_env("FLAG") == "1"
        from p in "posts", where: fragment("? IS NOT NULL", type(^["1"], #{spec})), select: p.id
        """)

      changes = diffs(source, mutators)
      assert {:logical, "not flag", "flag"} in changes

      refute Enum.any?(changes, fn {_family, original, _} ->
               original in [":integer", ":string", ":array"]
             end)

      assert_builds(source, & &1.q(), mutators)
    end
  end

  test "a pin computing a named binding or a window direction reaches core" do
    mutators = [mutators: [Mutare.Mutators.BooleanLiteral, {Mutare.Ecto, families: []}]]

    for query <- [
          ~s|from a in "posts", as: :a, join: b in "posts", as: :b, on: a.id != b.id, where: as(^(if true, do: :a, else: :b)).id == 1, select: a.id|,
          ~s|from a in "posts", as: :a, where: exists(from b in "posts", where: parent_as(^(if true, do: :a, else: :b)).id == b.id), select: a.id|,
          ~s|value = dynamic([p], over(row_number(), order_by: [{^(if true, do: :asc, else: :desc), p.id}]))\nfrom p in "posts", select: ^value|
        ] do
      source = fixture(query)

      assert {:boolean, "true", "false"} in diffs(source, mutators)
      assert_builds(source, & &1.q(), mutators)
    end
  end

  test "a window's inputs may read the bare column an ordering aggregate picks the row of" do
    for clauses <- [
          "select: sum(r.views) + over(sum(r.id)), order_by: min(r.user_id)",
          "select: sum(0) + over(filter(sum(r.id), true)), order_by: min(r.user_id)",
          ~s|select: sum(r.views) + over(fragment("first_value(id)")), order_by: min(r.user_id)|,
          "group_by: r.user_id, select: over(count(), partition_by: :views), order_by: min(r.id)",
          "group_by: r.user_id, windows: [w: [partition_by: r.views]], select: over(count(), :w), order_by: min(r.id)"
        ] do
      source =
        fixture("""
        from p in "posts", where: p.id in subquery(from r in "posts", #{clauses}), select: p.id
        """)

      aggregate = if clauses =~ "min(r.id)", do: "min(r.id)", else: "min(r.user_id)"
      assert_rewrite(source, [:aggregate], aggregate, String.replace(aggregate, "min", "max"))
      assert_builds(source, & &1.q(), only([:aggregate]))
    end
  end

  test "an EXISTS projection that splices observes the pinned list, whose length is an arity" do
    mutators = [mutators: [Mutare.Mutators.List, {Mutare.Ecto, families: []}]]

    source =
      fixture("""
      from p in "posts",
        where: exists(from r in "posts", select: fragment("max(?)", splice(^([1] ++ [2])))),
        select: p.id
      """)

    assert {:list, "[1] ++ [2]", "[1] -- [2]"} in diffs(source, mutators)
    assert_builds(source, & &1.q(), mutators)
  end

  test "a binary literal is a leaf in a projection and an ordering, not only in a condition" do
    for query <- [
          ~s|from p in MyApp.Post, select: <<0::unsigned-integer-size(128)>>|,
          ~s/MyApp.Post |> select([p], <<0::unsigned-integer-size(128)>>)/,
          ~s|from p in MyApp.Post, order_by: <<0::unsigned-integer-size(128)>>, select: p.id|,
          ~s|from p in MyApp.Post, select: {p.views + 1, <<0::8*16>>}|,
          ~s|from p in MyApp.Post, where: p.title == <<0::unsigned-integer-size(128)>>|
        ] do
      source = fixture(query)

      refute Enum.any?(ecto_diffs(source), fn {original, _mutated} ->
               String.starts_with?(original, ["0", "unsigned", "8"])
             end)

      assert_builds(source, & &1.q())
    end
  end
end
