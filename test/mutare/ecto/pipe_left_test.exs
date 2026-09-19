defmodule Mutare.Ecto.PipeLeftTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  @with_core [:all, {Mutare.Ecto, repo: MyApp.Repo}]

  test "direct and piped from keep a computed source's upstream mutations" do
    upstream = "MyApp.Post |> where([p], p.views > ^(n + 1))"

    for body <- ["from(#{upstream}, limit: 5)", "#{upstream} |> from(limit: 5)"] do
      source = """
      defmodule Q do
        import Ecto.Query
        def q(n), do: #{body}
      end
      """

      mutations = diffs(source, mutators: @with_core)
      assert {:arithmetic, "p.views > ^(n + 1)", "p.views > ^(n - 1)"} in mutations
      assert {:ecto, "p.views > ^(n + 1)", "p.views >= ^(n + 1)"} in mutations

      assert Enum.any?(mutations, fn {family, original, mutated} ->
               family == :ecto and original =~ "where" and mutated =~ "identity"
             end)

      refute Enum.any?(mutations, fn {family, _, _} -> family == :alias end)
      assert_compiles(source, mutators: @with_core)
    end
  end

  test "source routing agrees across spellings and query macro kinds" do
    alias Mutare.CallRouting.{ArgumentRoutes, Call}
    alias Mutare.Ecto.Host.Routing

    sources = [
      {"MyApp.Post", :raw},
      {~s("posts"), :raw},
      {~s({"posts", MyApp.Post}), :raw},
      {"p in MyApp.Post", :raw},
      {"[p, q] in query", :raw},
      {~s|fragment("SELECT 1 AS id")|, :raw},
      {"values([%{id: 1}], %{id: :integer})", :raw},
      {"query", :expression},
      {"build(n + 1)", :expression},
      {"query |> where([p], p.views > 1)", :expression}
    ]

    for {source, expected} <- sources,
        stage <- [
          "from(limit: 5)",
          "where([p], p.views > 1)",
          "limit(5)",
          "join(:inner, [p], u in MyApp.User, on: u.id == p.user_id)"
        ],
        piped? <- [false, true] do
      left = Sourceror.parse_string!(source)
      {name, meta, args} = Sourceror.parse_string!(stage)
      {args, pipe_left} = if piped?, do: {args, {:piped, left}}, else: {[left | args], :unpiped}

      call =
        Call.new({name, meta, args}, Ecto.Query, name, pipe_left, fn name, args ->
          {name, meta, args}
        end)

      routes = Routing.route_arguments(call, %{})

      actual =
        if piped?, do: ArgumentRoutes.piped(routes), else: hd(ArgumentRoutes.visible(routes))

      assert actual == expected, "#{source} through #{stage}, piped: #{piped?}"
    end
  end

  test "binding-pattern pipes deliver whole-call rewrites and static fallbacks" do
    for {body, expected} <- [
          {"(p in MyApp.Post) |> from(order_by: [asc: p.title])", "desc"},
          {"(p in MyApp.Post) |> from(having: p.views > subquery(from(q in MyApp.Post, select: max(q.views))))",
           ">="}
        ] do
      source = """
      defmodule Q do
        import Ecto.Query
        def q(n, query), do: #{body}
      end
      """

      assert Enum.any?(ecto_diffs(source), fn {_, mutated} -> mutated =~ expected end)
      assert_compiles(source, mutators: @with_core)
    end

    assert {"p.title", ""} in ecto_diffs("""
           defmodule Q do
             import Ecto.Query
             def q, do: (p in MyApp.Post) |> from(group_by: p.title)
           end
           """)
  end

  test "fragment sources remain SQL syntax with core enabled" do
    for body <- [
          ~s|from(fragment("SELECT 1 AS id"), select: [:id])|,
          ~s'fragment("SELECT 1 AS id") |> from(select: [:id])'
        ] do
      source = """
      defmodule Q do
        import Ecto.Query
        def q, do: #{body}
      end
      """

      refute Enum.any?(diffs(source, mutators: @with_core), fn {family, _, _} ->
               family == :string
             end)

      assert_compiles(source, mutators: @with_core)
    end
  end

  test "subquery producers skip piped binding reorders before family filtering" do
    source = """
    defmodule Q do
      import Ecto.Query
      def q(query) do
        from(p in MyApp.Post,
          where: p.id in subquery(([a, b] in query) |> from(where: a.id > b.id, select: a.id)))
      end
    end
    """

    for families <- [:all, [:comparison]] do
      opts = [mutators: [{Mutare.Ecto, families: families}]]
      mutations = ecto_diffs(source, opts)
      assert Enum.any?(mutations, fn {_, mutated} -> mutated =~ "a.id >= b.id" end)
      refute Enum.any?(mutations, fn {_, mutated} -> mutated =~ "[b, a]" end)
      assert_compiles(source, opts)
    end
  end

  test "computed subquery sources belong to core families" do
    for condition <- [
          "p.id in subquery(from(build(2), select: [:id]))",
          "p.id in subquery(build(2) |> from(select: [:id]))",
          "p.id in subquery(Ecto.Query.from(build(2), select: [:id]))",
          "p.id in subquery(build(2) |> limit(3))",
          "p.id in subquery(limit(build(2), 3))",
          "exists(from(build(2), select: [:id]))"
        ] do
      source = """
      defmodule Q do
        import Ecto.Query
        def build(n), do: from(MyApp.Post, limit: ^n)
        def q do
          from(p in MyApp.Post, where: #{condition})
        end
      end
      """

      for opts <- [[], [mutators: @with_core]] do
        refute Enum.any?(ecto_diffs(source, opts), fn {_, mutated} ->
                 Enum.any?(["build(3)", "build(1)", "build(0)"], &String.contains?(mutated, &1))
               end)

        assert_compiles(source, opts)
      end

      assert Enum.any?(diffs(source, mutators: @with_core), fn {family, _, mutated} ->
               family == :integer and mutated =~ "build(3)"
             end)

      suppressed =
        String.replace(
          source,
          "where: #{condition})",
          "where: #{condition}) # mutare:ignore[integer]"
        )

      recorded = sites(suppressed, mutators: @with_core)
      integers = Enum.filter(recorded, &(&1.mutator == :integer and &1.mutated_code =~ "build("))
      assert integers != []
      assert Enum.all?(integers, & &1.ignored)

      assert Enum.any?(recorded, &(&1.mutator == :ecto and not &1.ignored))
    end
  end
end

defmodule Mutare.Ecto.PipeLeftTest.Runtime do
  use ExUnit.Case, async: false

  import Mutare.Ecto.TestSupport

  test "composed subqueries without positional bindings render and build every upstream mutant" do
    upstream = "from(MyApp.Post, as: :q, where: as(:q).views > 2)"

    for inner <- ["#{upstream} |> limit(3)", "limit(#{upstream}, 3)"] do
      source = """
      defmodule Q do
        import Ecto.Query
        def q, do: from(MyApp.Post, where: exists(#{inner}))
      end
      """

      sites = assert_builds(source, & &1.q())

      for predicate <- ["as(:q).views >= 2", "as(:q).views > 3", "as(:q).views > 1"] do
        assert Enum.count(sites, &(&1.mutator == :ecto and &1.mutated_code =~ predicate)) == 1
      end
    end
  end

  test "values sources preserve field names and types with core enabled" do
    values = "values([%{id: 1}], %{id: :integer})"

    for body <- [
          "from(#{values}, select: [:id])",
          "#{values} |> from(select: [:id])",
          "limit(from(#{values}, select: [:id]), 3)",
          "from(#{values}, select: [:id]) |> limit(3)",
          "from(MyApp.Post, where: exists(from(#{values}, select: [:id])))"
        ] do
      source = """
      defmodule Q do
        import Ecto.Query
        def q, do: #{body}
      end
      """

      sites = sites(source, mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}])
      refute Enum.any?(sites, &(&1.mutator in [:atom, :integer]))

      # Whole-query return-value mutants can intentionally stop being queryables.
      assert_builds(source, & &1.q(),
        mutators: [:atom, :integer, {Mutare.Ecto, repo: MyApp.Repo}]
      )
    end
  end

  test "composed subqueries retain each upstream SQL mutant through the island seam" do
    upstream = "from(q in MyApp.Post, where: q.views > 5, select: q.id)"

    for inner <- [
          "#{upstream} |> limit(2)",
          "limit(#{upstream}, 2)",
          "#{upstream} |> where([q], q.id > 0) |> limit(2)"
        ],
        opts <- [[], [mutators: [:integer, :relational, {Mutare.Ecto, repo: MyApp.Repo}]]] do
      source = """
      defmodule Q do
        import Ecto.Query
        def q, do: from(p in MyApp.Post, where: p.id in subquery(#{inner}))
      end
      """

      sites = assert_builds(source, & &1.q(), opts)

      for predicate <- ["q.views >= 5", "q.views > 6", "q.views > 4", "q.views > 0"] do
        assert Enum.count(sites, &(&1.mutator == :ecto and &1.mutated_code =~ predicate)) == 1
      end

      assert Enum.count(sites, fn site ->
               site.mutator == :ecto and site.original_code =~ "q.views > 5" and
                 site.mutated_code =~ "select: q.id" and
                 not String.contains?(site.mutated_code, "q.views")
             end) == 1

      refute Enum.any?(sites, &(&1.mutator != :ecto and &1.mutated_code =~ "q.views"))
    end
  end

  test "computed subquery sources build under every relayed core mutant" do
    for inner <- [
          "from(build(2), select: [:id])",
          "build(2) |> from(select: [:id])",
          "build(2) |> limit(3)",
          "limit(build(2), 3)"
        ] do
      source = """
      defmodule Q do
        import Ecto.Query
        def build(n), do: from(MyApp.Post, limit: ^n)
        def q, do: from(p in MyApp.Post, where: p.id in subquery(#{inner}))
      end
      """

      sites = assert_builds(source, & &1.q(), mutators: [:integer, {Mutare.Ecto, families: :all}])
      assert Enum.any?(sites, &(&1.mutator == :integer and &1.mutated_code =~ "build(3)"))
    end
  end

  test "piped binding sources combine whole-call, hosted and bound mutants" do
    source = """
    defmodule Q do
      import Ecto.Query
      def q do
        (p in MyApp.Post)
        |> from(where: p.views > 5, order_by: [asc: p.title], group_by: p.title, limit: 5)
      end
    end
    """

    sites = assert_builds(source, & &1.q())

    assert Enum.any?(
             sites,
             &(&1.original_code == "p.views > 5" and &1.mutated_code == "p.views >= 5")
           )

    assert Enum.any?(sites, &(&1.original_code == "5" and &1.mutated_code == "6"))
    assert Enum.any?(sites, &(&1.mutated_code =~ "desc"))
    assert Enum.any?(sites, &(&1.original_code == "p.title" and &1.mutated_code == ""))
  end

  test "piped binding whole-call mutants build the same queries as direct spellings" do
    for clauses <- [
          "order_by: [asc: p.title], group_by: p.title",
          "having: p.views > subquery(from(q in MyApp.Post, select: max(q.views)))"
        ] do
      source = """
      defmodule Q do
        import Ecto.Query
        def direct, do: from(p in MyApp.Post, #{clauses})
        def piped, do: (p in MyApp.Post) |> from(#{clauses})
      end
      """

      {[module], sites} = Mutare.Test.compile_metamutant(source, mutators([]))
      assert query_shape(module.direct()) == query_shape(module.piped())

      outcomes = fn run ->
        baseline = query_shape(run.())

        sites
        |> Enum.map(fn site -> query_shape(Mutare.Test.with_active_mutant(site.id, run)) end)
        |> Enum.reject(&(&1 == baseline))
        |> MapSet.new()
      end

      direct = outcomes.(fn -> module.direct() end)
      assert MapSet.size(direct) > 0
      assert direct == outcomes.(fn -> module.piped() end)
    end
  end

  # Query expressions retain their source locations; spellings on different lines
  # should agree on every query field except those diagnostic locations.
  defp query_shape(value) when is_map(value) do
    value
    |> Map.drop([:file, :line])
    |> Map.to_list()
    |> Map.new(fn {key, child} -> {key, query_shape(child)} end)
  end

  defp query_shape(value) when is_list(value), do: Enum.map(value, &query_shape/1)

  defp query_shape(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&query_shape/1) |> List.to_tuple()

  defp query_shape(value), do: value

  test "piped source bindings and subsequent joins keep their original positions" do
    source = """
    defmodule Q do
      import Ecto.Query
      def q do
        ([p, u] in (MyApp.Post |> join(:inner, [p], u in MyApp.User, on: u.id == p.user_id)))
        |> from(join: c in MyApp.Post, on: c.user_id == u.id,
                where: p.views > c.views, select: {p.id, u.id, c.id})
      end
    end
    """

    {[module], sites} = Mutare.Test.compile_metamutant(source, mutators([]))

    {baseline, mutant} =
      Mutare.Test.observe_mutant(sites, {"p.views > c.views", "p.views >= c.views"}, fn ->
        module.q()
      end)

    assert [
             {:>, _,
              [{{:., _, [{:&, _, [0]}, :views]}, _, []}, {{:., _, [{:&, _, [2]}, :views]}, _, []}]}
           ] = Enum.map(baseline.wheres, & &1.expr)

    assert [{:>=, _, _}] = Enum.map(mutant.wheres, & &1.expr)
    assert baseline.joins == mutant.joins
    assert_builds(source, & &1.q())
  end
end
