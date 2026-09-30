defmodule Mutare.Ecto.StaticConditionTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import Mutare.Ecto.TestSupport

  alias Mutare.Ecto.{StaticCondition, Subquery}

  # The conditions the host cannot weave (`Mutare.Ecto.StaticCondition`). A subquery in a
  # `having`: weaving turns a valid static clause into a `having: ^dynamic(…)` Ecto rejects when
  # the query is *built*. And a condition under a binding declaration the plugin cannot
  # re-declare: the woven `dynamic/2` has no faithful list to carry. Their mutants must arrive as
  # whole-call rebuilds instead. `assert_compiles/2` cannot see a build failure (the module
  # compiles either way), so every delivery test here goes through `assert_builds/3`.

  @threshold ~s|subquery(from(t in "thresholds", select: max(t.value)))|

  defp mutated(src, opts \\ []), do: src |> ecto_diffs(opts) |> Enum.map(fn {_o, m} -> m end)

  # The rendered metamutant with whitespace runs collapsed, so an assertion on the woven
  # scaffolding does not depend on where the formatter breaks a line.
  defp rendered(src, opts \\ []),
    do: src |> metamutant(opts) |> String.replace(~r/\s+/, " ") |> String.replace("( ", "(")

  describe "Ecto's capability boundary (the premise)" do
    # Pinned against the installed Ecto, so the version matrix reports a line that moves it. A
    # failure here would not make the whole-call delivery wrong — it is valid either way — only
    # `Mutare.Ecto.Surface.dynamic_subqueries?/1` more conservative than it needs to be.
    setup do
      %{condition: dynamic([p], p.id > subquery(from(t in "thresholds", select: max(t.value))))}
    end

    test "a dynamic carrying a subquery builds in a where", %{condition: condition} do
      assert %Ecto.Query{wheres: [%{subqueries: [_]}]} = where("posts", ^condition)
      assert %Ecto.Query{wheres: [%{subqueries: [_]}]} = or_where("posts", ^condition)
    end

    test "the same dynamic raises in a having — at build time", %{condition: condition} do
      for build <- [&having("posts", ^&1), &or_having("posts", ^&1)] do
        assert_raise ArgumentError, ~r/subqueries are not allowed in `having`/, fn ->
          build.(condition)
        end
      end
    end

    test "while the static having it was woven from is valid" do
      query =
        from(p in "posts",
          group_by: p.user_id,
          having: count(p.id) > subquery(from(t in "thresholds", select: max(t.value))),
          select: p.user_id
        )

      assert %Ecto.Query{havings: [%{subqueries: [_]}]} = query
    end
  end

  describe "weavable?/2 — the clause and the expression together" do
    test "only a subquery in a clause that rejects a dynamic one is refused" do
      subquery = Sourceror.parse_string!("count(p.id) > #{@threshold}")
      plain = Sourceror.parse_string!("count(p.id) > 1")

      for clause <- [:where, :or_where, :having, :or_having],
          do: assert(StaticCondition.weavable?(clause, plain))

      for clause <- [:where, :or_where], do: assert(StaticCondition.weavable?(clause, subquery))
      for clause <- [:having, :or_having], do: refute(StaticCondition.weavable?(clause, subquery))
    end
  end

  describe "Subquery.present?/1 — Ecto's accumulating heads" do
    defp present?(code), do: code |> Sourceror.parse_string!() |> Subquery.present?()

    test "each wrapper counts, whatever its argument" do
      assert present?("p.id > subquery(q)")
      assert present?(~s|p.id > subquery(from(t in "t", select: t.id))|)
      assert present?("exists(q)")
      assert present?("not exists(from(t in T))")
      assert present?("p.x >= all(q)")
      assert present?("p.x == any(q)")
      assert present?("p.id in subquery(q)")
    end

    test "it is found at any depth, including a fragment's or an author macro's argument" do
      assert present?("p.a > 1 and (p.b < 2 or p.id in subquery(q))")
      assert present?(~s|fragment("? > ?", p.id, subquery(q))|)
      assert present?("over_threshold(p, subquery(q))")
    end

    test "a condition without one is not flagged" do
      refute present?("count(p.id) > 1 and p.role in ^roles")
      # A variable or field that merely shares a wrapper's name is not a unary call to it.
      refute present?("p.any == all")
    end

    test "a pin's interior is Elixir, never escaped — a wrapper there is not Ecto's" do
      refute present?("count(p.id) > ^Repo.one(subquery(q))")
      refute present?("p.ok == ^Enum.any?(list)")
    end
  end

  describe "a `from`'s having: clause" do
    @from_having """
    defmodule Q do
      import Ecto.Query

      def q do
        from p in "posts",
          where: p.views > 5,
          group_by: p.user_id,
          having: count(p.id) > #{@threshold},
          select: p.user_id
      end
    end
    """

    test "its mutants are the weave's, each reported at the expression it changed" do
      diffs = ecto_diffs(@from_having)

      # The outer comparison, anchored at the comparison itself…
      assert {"count(p.id) > #{@threshold}", "count(p.id) >= #{@threshold}"} in diffs
      # …and the subquery's own interior (`Mutare.Ecto.Subquery`), anchored inside it.
      assert {"max(t.value)", "min(t.value)"} in diffs
    end

    test "the having stays static while the where beside it still weaves" do
      rendered = rendered(@from_having)

      # The one woven condition is the `where`…
      assert rendered =~ "where: ^case mutare_active do"
      assert rendered =~ "Elixir.Ecto.Query.dynamic([p], p.views >= 5 )"
      # …and no `having` was pinned: every occurrence is a statically built clause.
      refute rendered =~ "having: ^"
      assert rendered =~ "count(p.id) >= subquery("
    end

    test "the query builds at baseline and under every mutant" do
      sites = assert_builds(@from_having, & &1.q())

      # Both deliveries are present in the one build: the woven `where`, the rebuilt `having`.
      assert Enum.any?(sites, &(&1.mutated_code == "p.views >= 5"))
      assert Enum.any?(sites, &(&1.mutated_code == "min(t.value)"))
    end
  end

  describe "every subquery-bearing having shape builds under every mutant" do
    test "a nested aliased query preserves the outer comparison and aggregate mutants" do
      threshold = ~s|subquery(Query.from(t in "thresholds", select: min(t.value)))|
      condition = "max(p.views) > #{threshold}"

      for query <- [
            ~s|Query.from(p in "posts", having: #{condition}, select: p.id)|,
            ~s|Query.having("posts", [p], #{condition})|,
            ~s'"posts" |> Query.having([p], #{condition})'
          ] do
        src = """
        defmodule Q do
          import Ecto.Query
          alias Ecto.Query
          def q, do: #{query}
        end
        """

        sites = assert_builds(src, & &1.q())
        diffs = Enum.map(sites, &{&1.original_code, &1.mutated_code})

        assert {condition, "max(p.views) >= #{threshold}"} in diffs
        assert {"max(p.views)", "min(p.views)"} in diffs
        assert {"min(t.value)", "max(t.value)"} in diffs
      end
    end

    test "the standalone having/3" do
      src = """
      defmodule Q do
        import Ecto.Query
        def q, do: having("posts", [p], count(p.id) > #{@threshold})
      end
      """

      assert "count(p.id) >= #{@threshold}" in mutated(src)
      refute metamutant(src) =~ "Query.dynamic("
      assert_builds(src, & &1.q())
    end

    test "a piped or_having" do
      src = """
      defmodule Q do
        import Ecto.Query
        def q, do: "posts" |> group_by([p], p.user_id) |> or_having([p], count(p.id) > #{@threshold})
      end
      """

      assert "count(p.id) >= #{@threshold}" in mutated(src)
      refute metamutant(src) =~ "Query.dynamic("
      assert_builds(src, & &1.q())
    end

    test "exists — a quantifier, which Ecto rewrites into a subquery" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in "posts",
            group_by: p.user_id,
            having: exists(from(t in "thresholds", where: t.value > 3)),
            select: p.user_id
        end
      end
      """

      # The polarity flip and the interior swaps alike arrive as rebuilds.
      assert ~s|not exists(from(t in "thresholds", where: t.value > 3))| in mutated(src)
      assert "t.value >= 3" in mutated(src)
      refute metamutant(src) =~ "Query.dynamic("
      assert_builds(src, & &1.q())
    end

    test "subquery/1 over a variable — no inline from to recurse, still a subquery" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(sq) do
          from p in "posts",
            group_by: p.user_id,
            having: count(p.id) > subquery(sq),
            select: p.user_id
        end
      end
      """

      assert mutated(src) |> Enum.member?("count(p.id) >= subquery(sq)")
      refute metamutant(src) =~ "Query.dynamic("
      assert_builds(src, & &1.q(from(t in "thresholds", select: max(t.value))))
    end

    test "a pin beside the subquery: its interior is still sub-contracted, delivered as a rebuild" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(floor) do
          from p in "posts",
            group_by: p.user_id,
            having: count(p.id) > #{@threshold} and max(p.views) > ^(floor + 1),
            select: p.user_id
        end
      end
      """

      # Core's arithmetic family alone beside the plugin: under `:all`, `:return_value` would
      # swap the function's result for `nil`, a mutant that was never going to be a queryable.
      opts = [mutators: [Mutare.Mutators.Arithmetic, {Mutare.Ecto, repo: MyApp.Repo}]]

      # Core's arithmetic family mutated the pin's interior (`Mutare.Ecto.Island`), relayed as a
      # rebuild of the whole `from`, while the report retains the arithmetic origin.
      assert [{:arithmetic, "floor + 1", relayed}] =
               Enum.filter(diffs(src, opts), &match?({:arithmetic, _, _}, &1))

      assert relayed == "floor - 1"
      # It rides the same static delivery as the plugin's own mutants.
      refute rendered(src, opts) =~ "having: ^"
      assert_builds(src, & &1.q(3), opts)
    end

    test "an inner from inside a pin interior — core lowers a nested host's targets" do
      # Core rebuilds a nested host target as `splice(wrap(mutant))` — still `having: ^dynamic(…)`
      # — so an undeclined inner `having` would ship mutants that raise once selected (spurious
      # kills; baseline is unaffected there, the interior not being woven). Declined, its mutants
      # reach core through the whole-call offer instead.
      src = """
      defmodule Q do
        import Ecto.Query

        def q(ids) do
          from(u in "users",
            where:
              u.id in ^Enum.map(ids, fn _ ->
                built(
                  from(p in "posts",
                    group_by: p.user_id,
                    having: count(p.id) > #{@threshold},
                    select: p.user_id
                  )
                )
              end)
          )
        end

        # Forces the inner query to be built, Repo-free.
        defp built(%Ecto.Query{}), do: 1
      end
      """

      sites = assert_builds(src, & &1.q([1]))
      assert Enum.any?(sites, &(&1.mutated_code =~ "count(p.id) >= subquery("))
    end
  end

  describe "what still weaves (the rule declines nothing else)" do
    test "a where with a subquery — the where kind accepts a dynamic one" do
      src = """
      defmodule Q do
        import Ecto.Query
        def q, do: from(p in "posts", where: p.id > #{@threshold}, select: p.id)
      end
      """

      assert rendered(src) =~ "Elixir.Ecto.Query.dynamic([p], p.id >= subquery("
      assert_builds(src, & &1.q())
    end

    test "a having without one" do
      src = """
      defmodule Q do
        import Ecto.Query
        def q, do: from(p in "posts", group_by: p.user_id, having: count(p.id) > 1, select: p.user_id)
      end
      """

      assert rendered(src) =~ "Elixir.Ecto.Query.dynamic([p], count(p.id) >= 1)"
      assert_builds(src, & &1.q())
    end
  end

  describe "a subquery only an author macro's expansion reveals" do
    # Reading source cannot see it, so the macro call itself decides: a condition holding a call
    # Ecto can only be expanding is rebuilt, and `having: over_threshold(p) and count(p.id) > 1`
    # builds without `condition_delivery: :static`.
    @macros """
    defmodule Macros do
      defmacro over_threshold(p) do
        quote do
          count(unquote(p).id) > subquery(from(t in "thresholds", select: max(t.value)))
        end
      end
    end
    """

    defp with_macro(having_clauses) do
      """
      #{@macros}
      defmodule Q do
        import Ecto.Query
        import Macros

        def q do
          from(p in "posts", group_by: p.user_id, #{having_clauses}, select: p.user_id)
        end
      end
      """
    end

    test "the macro call alone has no mutants, so it is never woven" do
      src = with_macro("having: over_threshold(p)")

      refute rendered(src) =~ "having: ^"
      assert_builds(src, & &1.q())
    end

    test "a larger condition holding the macro is rebuilt, under either delivery policy" do
      src = with_macro("having: over_threshold(p) and count(p.id) > 1")

      for opts <- [[], [mutators: [{Mutare.Ecto, condition_delivery: :static}]]] do
        refute metamutant(src, opts) =~ "Query.dynamic("
        assert {"count(p.id) > 1", "count(p.id) >= 1"} in ecto_diffs(src, opts)
        assert_builds(src, & &1.q(), opts)
      end
    end

    test "given a clause of its own, only the clause beside it weaves — and the query builds" do
      src = with_macro("having: over_threshold(p), having: count(p.id) > 1")

      assert rendered(src) =~ "having: over_threshold(p), having: ^case mutare_active do"
      sites = assert_builds(src, & &1.q())
      assert Enum.any?(sites, &(&1.mutated_code == "count(p.id) >= 1"))
    end
  end

  describe "a call Ecto can only be expanding, outside a pin or subquery argument" do
    defp woven?(condition) do
      """
      defmodule Q do
        import Ecto.Query
        import Mutare.Ecto.QueryMacros

        def q(values) do
          from(p in "posts", where: #{condition}, select: p.id)
        end
      end
      """
      |> metamutant()
      |> String.contains?("Query.dynamic(")
    end

    test "rebuilds a condition an author macro's expansion may splice into" do
      refute woven?("member_sql(p.id, ^values) and p.views > 10")
      refute woven?("p.views > 10 or not member_sql(p.id, ^values)")
    end

    test "rebuilds a condition whose type/2 operand Ecto can only be expanding" do
      refute woven?("p.id > type(author_sql(^values), :integer)")
    end

    test "reads neither a pin's interior nor a subquery wrapper's argument" do
      assert woven?("p.views > ^Enum.count(values) and p.id > 0")
      # Pruning keeps the pin itself, which `type/2` reads as its operand.
      assert woven?("p.id > type(^values, :integer)")

      assert woven?(
               ~s|p.id in subquery(from(r in "rows", where: member_sql(r.id, ^values), select: r.id)) and p.views > 10|
             )
    end

    test "a woven typed pin builds under every mutant" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(n), do: from(p in "posts", where: p.id > type(^n, :integer), select: p.id)
      end
      """

      assert rendered(src) =~ "Query.dynamic("
      assert {"p.id > type(^n, :integer)", "p.id >= type(^n, :integer)"} in ecto_diffs(src)
      assert_builds(src, & &1.q(10))
    end
  end

  describe "a keyword filter is never the fallback's (`Mutare.Ecto.Host.Condition.shape/1`)" do
    # Ecto's filter builder accumulates a pair value's subquery too, so a subquery-bearing filter
    # is not weavable — but the host would not weave a filter anyway: its pairs are routed to
    # core one by one. The fallback serves what the weave would have carried, which for a filter
    # is nothing; it must not walk the list as a predicate.
    @filter_having """
    defmodule Q do
      import Ecto.Query

      def q do
        from p in "posts",
          group_by: p.user_id,
          having: [user_id: 3, score: #{@threshold}],
          select: p.user_id
      end
    end
    """

    test "no column key is renamed, under every family — in a from or the standalone having/3" do
      standalone = """
      defmodule Q do
        import Ecto.Query
        def q, do: having("posts", [p], user_id: 3, score: #{@threshold})
      end
      """

      for src <- [@filter_having, standalone] do
        mutateds =
          src
          |> diffs(mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo, families: :all}])
          |> Enum.map(fn {_family, _original, mutated} -> mutated end)

        refute Enum.any?(mutateds, &(&1 =~ ~r/mutare:|:mutare =>/))
      end
    end

    test "the plugin's only mutants are clause drops; the scalar pair is core's alone" do
      # The whole-`from` drops of the filter and of the `group_by:` beside it
      # (`Mutare.Ecto.Query`) — no catalog mutant of a pair.
      assert [{"[user_id: 3, score: " <> _, ""}, {"p.user_id", ""}] = ecto_diffs(@filter_having)

      opts = [mutators: [Mutare.Mutators.IntegerLiteral, {Mutare.Ecto, repo: MyApp.Repo}]]

      integer =
        for {:integer, original, mutated} <- diffs(@filter_having, opts), do: {original, mutated}

      assert {"3", "4"} in integer
      refute rendered(@filter_having, opts) =~ "Query.dynamic("
      assert_builds(@filter_having, & &1.q(), opts)
    end

    test "nor is a filter under a declaration the plugin cannot re-declare" do
      # Such a declaration sends a *predicate* to the fallback (the describe below); a filter in
      # the same position stays core's, per pair — whether it is written in a `from`, as a
      # condition macro's argument, or as a join's `on:`.
      every_family = [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo, families: :all}]]

      # The build narrows core to the integer family: `:all` would also mutate the test's own
      # `{index, …}` wrapper, which the build unwraps.
      pair_value = [
        mutators: [
          Mutare.Mutators.IntegerLiteral,
          {Mutare.Ecto, repo: MyApp.Repo, families: :all}
        ]
      ]

      for stage <- [
            "from([{p, index}] in query, where: [score: 5], limit: 10)",
            "where(query, [{p, index}], score: 5)",
            ~s|from([{p, index}] in query, join: c in "comments", on: [score: 5])|,
            ~s|join(query, :inner, [{p, index}], c in "comments", on: [score: 5])|
          ] do
        src = """
        defmodule Q do
          import Ecto.Query
          def q(query, index), do: {index, #{stage}}
        end
        """

        mutateds = for {_family, _original, mutated} <- diffs(src, every_family), do: mutated
        refute Enum.any?(mutateds, &(&1 =~ ~r/mutare:|:mutare =>/)), stage

        integer =
          for {:integer, original, mutated} <- diffs(src, pair_value), do: {original, mutated}

        assert {"5", "6"} in integer, stage
        assert_builds(src, &elem(&1.q(from(p in "posts"), 0), 1), pair_value)
      end
    end
  end

  describe "a condition under a declaration the plugin cannot re-declare" do
    # `Mutare.Ecto.Binding` reads a computed index and a name that calls a function narrower than
    # Ecto does: a woven `dynamic/2` re-declares its list beside the written one, so either would
    # be evaluated twice. Rebuilt whole-call, every branch keeps the declaration as written.

    for {label, declaration} <- [
          {"a computed index", "{p, index}"},
          {"a name that calls a function", "{^name(), p}"}
        ] do
      test "#{label}: each hosted form is rebuilt, and builds under every mutant" do
        declaration = unquote(declaration)

        for {stage, swap} <- [
              {"where(query, [#{declaration}], p.views > 10)", {"p.views > 10", "p.views >= 10"}},
              {"query |> having([#{declaration}], p.views > 10)",
               {"p.views > 10", "p.views >= 10"}},
              {"from([#{declaration}] in query, where: p.views > 10)",
               {"p.views > 10", "p.views >= 10"}},
              {~s|from([#{declaration}] in query, join: c in "comments", on: c.score > p.views)|,
               {"c.score > p.views", "c.score >= p.views"}},
              {~s|join(query, :inner, [#{declaration}], c in "comments", on: c.score > p.views)|,
               {"c.score > p.views", "c.score >= p.views"}}
            ] do
          src = """
          defmodule Q do
            import Ecto.Query
            def q(query, index), do: {index, #{stage}}
            def name, do: :post
          end
          """

          assert swap in ecto_diffs(src), stage
          refute metamutant(src) =~ "Query.dynamic(", stage
          # The base names its binding for `name/0` and holds it at the index `index` names.
          assert_builds(src, &elem(&1.q(from(p in "posts", as: :post), 0), 1))
        end
      end
    end

    test "an association on: under an unread declaration is rebuilt" do
      for stage <- [
            "from([{p, index}] in query, join: c in assoc(p, :comments), on: c.score > 2)",
            "join(query, :inner, [{p, index}], c in assoc(p, :comments), on: c.score > 2)"
          ] do
        src = """
        defmodule Q do
          import Ecto.Query
          def q(query, index), do: {index, #{stage}}
        end
        """

        assert {"c.score > 2", "c.score >= 2"} in ecto_diffs(src), stage
        assert_compiles(src)
      end
    end
  end

  describe "each condition is delivered exactly once" do
    test "a declined having records the same mutants a woven where does — no more, no fewer" do
      # The same condition text under both clause kinds: the `where` weaves, the `having`
      # rebuilds. The two report a site differently (a woven site spans the condition, a rebuilt
      # one is anchored at the node), so the comparison is over each site's `variant`: an equal
      # multiset means the fallback neither drops a mutant the weave would carry nor doubles one
      # by serving a condition the host also took.
      source = fn clause ->
        """
        defmodule Q do
          import Ecto.Query
          def q, do: from(p in "posts", #{clause}: p.id > #{@threshold} and p.views < 9)
        end
        """
      end

      variants = fn clause ->
        clause |> source.() |> sites() |> Enum.map(& &1.variant) |> Enum.sort()
      end

      hosted = variants.("where")

      assert ["aggregate", "max"] in hosted
      assert ["comparison", ">"] in hosted
      assert variants.("having") == hosted
    end

    test "an unread declaration records the same mutants a readable one does" do
      # The same calls under `[p]` (woven) and `[{p, index}]` (rebuilt), compared as above.
      source = fn declaration ->
        """
        defmodule Q do
          import Ecto.Query

          def q(query, index) do
            {index,
             [
               where(query, [#{declaration}], p.id > 1 and p.views < 9),
               from([#{declaration}] in query, where: p.id > 1, having: count(p.id) < 9),
               join(query, :inner, [#{declaration}], c in "comments", on: c.post_id == p.id)
             ]}
          end
        end
        """
      end

      variants = fn declaration ->
        declaration |> source.() |> sites() |> Enum.map(& &1.variant) |> Enum.sort()
      end

      woven = variants.("p")

      assert ["comparison", ">"] in woven
      assert ["aggregate", "count"] not in woven
      assert rendered(source.("p")) =~ "Query.dynamic("
      refute rendered(source.("{p, index}")) =~ "Query.dynamic("
      assert variants.("{p, index}") == woven
    end
  end
end
