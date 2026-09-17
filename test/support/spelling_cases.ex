defmodule Mutare.Ecto.SpellingCases do
  @moduledoc false
  # The **spelling suite** — *does the same query get the same mutants however it is written?* —
  # and the pin under the README's "Coverage by spelling" tables: every row there is a `describe`
  # here, the gaps included. A gap is asserted as exactly what it is (the family reaches *no*
  # statement in that spelling), so closing one fails its test until the README row is rewritten
  # — a gap is declared, never discovered by respelling a query.
  #
  # A fixture is one query body; a family's **capability** on it is the set of statements its
  # mutants reach (`Mutare.Ecto.SemanticHarness.outcome/3`), which is independent of spelling and
  # of delivery by construction. Each test states that set as hand-written queries, so it reads as
  # "these are the mutated queries" rather than as rendered diffs — which differ between
  # spellings even where the mutants agree (`"p.active" → ""` vs. `where(…) → identity()`).
  #
  # The same normal form carries the second distinction the suite holds: a **stage drop** that
  # weakens a query still runs, as another statement, while one that removes something a later
  # stage requires breaks — at build, plan, or run (`t:Mutare.Ecto.SemanticHarness.outcome/0`).
  #
  # A `use` template like `Mutare.Ecto.SemanticCases`, instantiated per engine by the same entry
  # file: the statements are engine-specific text, and every comparison is within one engine.
  defmacro __using__(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote location: :keep do
      @repo unquote(opts[:repo])

      import Ecto.Query

      alias Mutare.Ecto.SemanticHarness, as: H

      setup_all do: H.start_repo!(@repo)

      # The run's mutators for a fixture that needs core's families beside the plugin's — a
      # keyword-shorthand value, a pin's interior, and an upstream expression are all core's.
      @with_core [mutators: [:all, {Mutare.Ecto, repo: @repo}]]

      # Compile one spelling: a module whose `q/0` is `body`, with `helpers` (further defs the
      # body calls — a query another function builds) beside it. Every fixture is compiled under
      # the same module name; core wraps each compilation uniquely.
      defp fixture(body, opts \\ []) do
        {helpers, opts} = Keyword.pop(opts, :helpers, "")

        H.compile(
          """
          defmodule Q do
            import Ecto.Query
            #{helpers}
            def q do
              #{body}
            end
          end
          """,
          [repo: @repo] ++ opts
        )
      end

      # The statement a spelling runs as, unmutated.
      defp baseline({mod, _sites}), do: H.outcome(@repo, 0, &mod.q/0)

      # A family's capability on a fixture: the outcomes its mutants reach.
      defp reached({mod, sites}, family) do
        for site <- sites, H.family(site) == Atom.to_string(family), into: MapSet.new() do
          H.outcome(@repo, site.id, &mod.q/0)
        end
      end

      # The outcome of dropping the one pipe stage whose source matches `stage`.
      defp dropped({mod, sites}, stage) do
        id = Mutare.Test.site_id(sites, {stage, ~r/identity/})
        H.outcome(@repo, id, &mod.q/0)
      end

      # The outcomes of hand-written queries — what a capability is stated as.
      defp statements(queries),
        do: MapSet.new(queries, fn query -> H.outcome(@repo, 0, fn -> query end) end)

      # Compile the spellings of one query, checking that they *are* one query: a pair whose
      # baselines differ would compare the mutants of two different queries.
      defp spellings(bodies, opts \\ []) do
        compiled = Map.new(bodies, fn {name, body} -> {name, fixture(body, opts)} end)
        [first | rest] = Enum.map(compiled, fn {_name, fixture} -> baseline(fixture) end)

        assert {:runs, _sql, _params} = first
        assert Enum.all?(rest, &(&1 == first)), "the spellings are not the same query"

        compiled
      end

      # Every spelling reaches exactly `queries` under `family`.
      defp assert_same(compiled, family, queries) do
        expected = statements(queries)

        for {name, fixture} <- compiled do
          assert reached(fixture, family) == expected,
                 "the #{name} spelling's #{family} mutants reach other statements"
        end
      end

      # ── one capability, both spellings ──────────────────────────────────────────────────────

      describe "Same in both spellings — a `where` condition, and its drop" do
        setup do
          %{
            compiled:
              spellings(
                from: ~S|from(p in "posts", where: p.views > 5, select: p.id)|,
                direct: ~S|select(where("posts", [p], p.views > 5), [p], p.id)|,
                pipe: ~S'"posts" |> where([p], p.views > 5) |> select([p], p.id)'
              )
          }
        end

        test "the operator swap", %{compiled: compiled} do
          assert_same(compiled, :comparison, [
            from(p in "posts", where: p.views >= 5, select: p.id)
          ])
        end

        test "the literal's off-by-one and zero", %{compiled: compiled} do
          assert_same(compiled, :integer_literal, [
            from(p in "posts", where: p.views > 6, select: p.id),
            from(p in "posts", where: p.views > 4, select: p.id),
            from(p in "posts", where: p.views > 0, select: p.id)
          ])
        end

        test "the filter drop", %{compiled: compiled} do
          assert_same(compiled, :filter_drop, [from(p in "posts", select: p.id)])
        end
      end

      describe "Same in both spellings — a `having` condition" do
        test "the aggregate and the operator inside it" do
          compiled =
            spellings(
              from:
                ~S|from(p in "posts", group_by: p.user_id, having: sum(p.views) > 5, select: p.user_id)|,
              pipe:
                ~S'"posts" |> group_by([p], p.user_id) |> having([p], sum(p.views) > 5) |> select([p], p.user_id)'
            )

          assert_same(compiled, :aggregate, [
            from(p in "posts",
              group_by: p.user_id,
              having: avg(p.views) > 5,
              select: p.user_id
            )
          ])

          assert_same(compiled, :comparison, [
            from(p in "posts",
              group_by: p.user_id,
              having: sum(p.views) >= 5,
              select: p.user_id
            )
          ])
        end
      end

      describe "Same in both spellings — a join's `on:` condition" do
        test "the operator swap" do
          compiled =
            spellings(
              from:
                ~S|from(p in "posts", join: c in "comments", on: c.post_id == p.id, select: {p.id, c.id})|,
              pipe:
                ~S'"posts" |> join(:inner, [p], c in "comments", on: c.post_id == p.id) |> select([p, c], {p.id, c.id})'
            )

          assert_same(compiled, :comparison, [
            from(p in "posts",
              join: c in "comments",
              on: c.post_id != p.id,
              select: {p.id, c.id}
            )
          ])
        end
      end

      describe "Same in both spellings — a keyword-shorthand value (core's families, pinned)" do
        test "the integer family's mutants, delivered through `^`" do
          compiled =
            spellings(
              [
                from: ~S|from(p in "posts", where: [views: 5], select: p.id)|,
                pipe: ~S'"posts" |> where(views: 5) |> select([p], p.id)'
              ],
              @with_core
            )

          assert_same(compiled, :integer, [
            from(p in "posts", where: [views: ^6], select: p.id),
            from(p in "posts", where: [views: ^4], select: p.id),
            from(p in "posts", where: [views: ^0], select: p.id)
          ])
        end
      end

      describe "Same in both spellings — a literal bound" do
        test "both bumps (pinned) and the drop" do
          compiled =
            spellings(
              from: ~S|from(p in "posts", order_by: p.id, limit: 2, select: p.id)|,
              pipe: ~S'"posts" |> order_by([p], p.id) |> limit(2) |> select([p], p.id)'
            )

          assert_same(compiled, :bound, [
            from(p in "posts", order_by: p.id, limit: ^3, select: p.id),
            from(p in "posts", order_by: p.id, limit: ^1, select: p.id),
            from(p in "posts", order_by: p.id, select: p.id)
          ])
        end
      end

      describe "Same in both spellings — an ordering" do
        test "the direction flip, of a written direction and of an implicit one" do
          for ordering <- ["[asc: p.views]", "p.views"] do
            compiled =
              spellings(
                from: ~s|from(p in "posts", order_by: #{ordering}, select: p.id)|,
                pipe: ~s'"posts" |> order_by([p], #{ordering}) |> select([p], p.id)'
              )

            assert_same(compiled, :ordering, [
              from(p in "posts", order_by: [desc: p.views], select: p.id)
            ])
          end
        end

        test "the nulls-placement flip" do
          compiled =
            spellings(
              from: ~S|from(p in "posts", order_by: [asc_nulls_first: p.views], select: p.id)|,
              pipe: ~S'"posts" |> order_by([p], asc_nulls_first: p.views) |> select([p], p.id)'
            )

          assert_same(compiled, :ordering_nulls, [
            from(p in "posts", order_by: [asc_nulls_last: p.views], select: p.id)
          ])
        end
      end

      describe "Same in both spellings — a computed `select` / `order_by` value" do
        test "the aggregate swap" do
          compiled =
            spellings(
              from: ~S|from(p in "posts", select: sum(p.views))|,
              pipe: ~S'"posts" |> select([p], sum(p.views))'
            )

          assert_same(compiled, :aggregate, [from(p in "posts", select: avg(p.views))])
        end

        test "the arithmetic swap, in a projection and in a sort key" do
          compiled =
            spellings(
              from: ~S|from(p in "posts", order_by: [desc: p.views * 2], select: p.views + p.id)|,
              pipe: ~S'"posts" |> order_by([p], desc: p.views * 2) |> select([p], p.views + p.id)'
            )

          assert_same(compiled, :arithmetic, [
            from(p in "posts", order_by: [desc: p.views / 2], select: p.views + p.id),
            from(p in "posts", order_by: [desc: p.views * 2], select: p.views - p.id)
          ])
        end

        test "the coalesce fallback drop" do
          compiled =
            spellings(
              from: ~S|from(p in "posts", select: coalesce(p.views, 0))|,
              pipe: ~S'"posts" |> select([p], coalesce(p.views, 0))'
            )

          assert_same(compiled, :coalesce, [from(p in "posts", select: p.views)])
        end
      end

      describe "Same in both spellings — a join's kind" do
        test "`left_join:` and `join(q, :left, …)` both narrow to the inner join" do
          compiled =
            spellings(
              from:
                ~S|from(p in "posts", left_join: c in "comments", on: c.post_id == p.id, select: {p.id, c.id})|,
              direct:
                ~S|select(join("posts", :left, [p], c in "comments", on: c.post_id == p.id), [p, c], {p.id, c.id})|,
              pipe:
                ~S'"posts" |> join(:left, [p], c in "comments", on: c.post_id == p.id) |> select([p, c], {p.id, c.id})'
            )

          assert_same(compiled, :join_type, [
            from(p in "posts",
              inner_join: c in "comments",
              on: c.post_id == p.id,
              select: {p.id, c.id}
            )
          ])
        end
      end

      describe "Same in both spellings — a set operation" do
        test "`intersect` ↔ `except`" do
          compiled =
            spellings(
              [
                from: ~S|from(p in "posts", select: p.id, intersect: ^viewed())|,
                pipe: ~S'"posts" |> select([p], p.id) |> intersect(^viewed())'
              ],
              helpers: ~S|defp viewed, do: from(p in "posts", where: p.published, select: p.id)|
            )

          viewed = from(p in "posts", where: p.published, select: p.id)

          assert_same(compiled, :combination, [
            from(p in "posts", select: p.id, except: ^viewed)
          ])
        end
      end

      describe "Same in both spellings — a written binding list" do
        # One list each: the `from` form's is its *source* list, which every clause resolves
        # through, where a pipeline re-declares a list per stage and reorders each on its own.
        test "the transposition" do
          compiled =
            spellings(
              [
                from: ~S|from([p, c] in joined(), where: c.id > p.id)|,
                pipe: ~S'joined() |> where([p, c], c.id > p.id)'
              ],
              helpers: ~S"""
              defp joined do
                from(p in "posts", join: c in "comments", on: c.post_id == p.id, select: p.id)
              end
              """
            )

          assert_same(compiled, :binding_reorder, [
            from(p in "posts",
              join: c in "comments",
              on: c.post_id == p.id,
              where: p.id > c.id,
              select: p.id
            )
          ])
        end
      end

      # ── the gaps: one spelling only ─────────────────────────────────────────────────────────

      describe "Gap — a clause other than a filter or a bound drops from a pipeline only" do
        test "a join, a grouping, a `distinct` and a `preload` each drop as a stage, never as a `from` key" do
          %{from: from, pipe: pipe} =
            spellings(
              [
                from: ~S"""
                from(p in Post,
                  join: c in "comments",
                  on: c.post_id == p.id,
                  group_by: p.id,
                  distinct: true,
                  preload: [:user]
                )
                """,
                pipe: ~S"""
                Post
                |> join(:inner, [p], c in "comments", on: c.post_id == p.id)
                |> group_by([p], p.id)
                |> distinct(true)
                |> preload([:user])
                """
              ],
              helpers: "alias MyApp.Post"
            )

          assert reached(from, :clause_drop) == MapSet.new()

          assert reached(pipe, :clause_drop) ==
                   statements([
                     from(p in MyApp.Post, group_by: p.id, distinct: true, preload: [:user]),
                     from(p in MyApp.Post,
                       join: c in "comments",
                       on: c.post_id == p.id,
                       distinct: true,
                       preload: [:user]
                     ),
                     from(p in MyApp.Post,
                       join: c in "comments",
                       on: c.post_id == p.id,
                       group_by: p.id,
                       preload: [:user]
                     ),
                     # A preload changes no statement — it is a second query — so its drop lands
                     # on the baseline's.
                     from(p in MyApp.Post,
                       join: c in "comments",
                       on: c.post_id == p.id,
                       group_by: p.id,
                       distinct: true
                     )
                   ])
        end
      end

      describe "Gap — an upstream query expression is core's in a composable stage only" do
        test "`from p in recent(2)` keeps the source raw; `where(recent(2), …)` hands it to core" do
          %{from: from, direct: direct, pipe: pipe} =
            spellings(
              [
                from: ~S|from(p in recent(2), where: p.published)|,
                direct: ~S|where(recent(2), [p], p.published)|,
                pipe: ~S'recent(2) |> where([p], p.published)'
              ],
              [
                helpers:
                  ~S|defp recent(n), do: from(p in "posts", where: p.views > ^n, select: p.id)|
              ] ++ @with_core
            )

          recent = fn n ->
            from(p in "posts", where: p.views > ^n, where: p.published, select: p.id)
          end

          assert reached(from, :integer) == MapSet.new()
          assert reached(direct, :integer) == statements([recent.(3), recent.(1), recent.(0)])
          assert reached(pipe, :integer) == statements([recent.(3), recent.(1), recent.(0)])
        end
      end

      describe "Gap — a schema or table name is held back from core, except on a pipe's left" do
        # The classifier reads a call's visible arguments; a pipe's left side is not one.
        test "`Post |> where(…)` hands `Post` to core's alias family; every other spelling keeps it" do
          %{from: from, piped_from: piped_from, direct: direct, pipe: pipe} =
            spellings(
              [
                from: ~S|from(p in Post, where: p.published)|,
                piped_from: ~S'Post |> from(as: :p, where: as(:p).published)',
                direct: ~S|where(Post, [p], p.published)|,
                pipe: ~S'Post |> where([p], p.published)'
              ],
              [helpers: "alias MyApp.Post"] ++ @with_core
            )

          for held_back <- [from, piped_from, direct],
              do: assert(reached(held_back, :alias) == MapSet.new())

          # `Mutare.Mutant |> where(…)`: no such queryable.
          assert reached(pipe, :alias) == MapSet.new([{:breaks, :build}])
        end

        test "likewise a table name, and core's string family" do
          %{direct: direct, pipe: pipe} =
            spellings(
              [
                direct: ~S|select(where("posts", [p], p.published), [p], p.id)|,
                pipe: ~S'"posts" |> where([p], p.published) |> select([p], p.id)'
              ],
              @with_core
            )

          assert reached(direct, :string) == MapSet.new()

          # `""` and `"mutare"`: no such table.
          assert reached(pipe, :string) == MapSet.new([{:breaks, :run}])
        end
      end

      # ── one spelling, written in different places ───────────────────────────────────────────

      describe "Placement — a subquery's interior is mutated when it is an inline `from`" do
        @outer ~S|from(p in "posts", where: p.id in subquery(INNER), select: p.id)|

        test "an inline pipeline, and a `from`-source subquery, are not entered" do
          inline_from =
            fixture(
              String.replace(
                @outer,
                "INNER",
                ~S|from(c in "comments", where: c.score > 3, select: c.post_id)|
              )
            )

          inline_pipe =
            fixture(
              String.replace(
                @outer,
                "INNER",
                ~S'"comments" |> where([c], c.score > 3) |> select([c], c.post_id)'
              )
            )

          from_source =
            fixture(~S"""
            from(s in subquery(from(c in "comments", where: c.score > 3, select: %{id: c.post_id})),
              select: s.id
            )
            """)

          assert baseline(inline_from) == baseline(inline_pipe)

          inner = from(c in "comments", where: c.score >= 3, select: c.post_id)

          assert reached(inline_from, :comparison) ==
                   statements([from(p in "posts", where: p.id in subquery(inner), select: p.id)])

          assert reached(inline_pipe, :comparison) == MapSet.new()
          assert reached(from_source, :comparison) == MapSet.new()
        end

        test "built first, the same subquery is an ordinary query and gets every family" do
          built_first =
            fixture(~S"""
            inner = from(c in "comments", where: c.score > 3, select: c.post_id)
            from(p in "posts", where: p.id in subquery(inner), select: p.id)
            """)

          inner = from(c in "comments", where: c.score >= 3, select: c.post_id)

          assert reached(built_first, :comparison) ==
                   statements([from(p in "posts", where: p.id in subquery(inner), select: p.id)])
        end
      end

      describe "Placement — a `^` pin's interior is core's inside a condition only" do
        # Two, without an integer literal of its own for core to mutate.
        @sized "defp size, do: length([:a, :b])"

        test "`where: … > ^(size() + 1)` is sub-contracted; `limit: ^(size() + 1)` is left alone" do
          condition =
            fixture(
              ~S|from(p in "posts", where: p.views > ^(size() + 1), select: p.id)|,
              [helpers: @sized] ++ @with_core
            )

          bound =
            fixture(
              ~S|from(p in "posts", limit: ^(size() + 1), select: p.id)|,
              [helpers: @sized] ++ @with_core
            )

          extracted =
            fixture(
              ~S"""
              page = size() + 1
              from(p in "posts", limit: ^page, select: p.id)
              """,
              [helpers: @sized] ++ @with_core
            )

          assert reached(condition, :integer) ==
                   statements([
                     from(p in "posts", where: p.views > ^4, select: p.id),
                     from(p in "posts", where: p.views > ^2, select: p.id)
                   ])

          assert reached(bound, :integer) == MapSet.new()

          assert reached(extracted, :integer) ==
                   statements([
                     from(p in "posts", limit: ^4, select: p.id),
                     from(p in "posts", limit: ^2, select: p.id)
                   ])
        end

        test "a `dynamic` written inside a pinned `order_by` is left alone; built first, it is mutated" do
          inline =
            fixture(
              ~S|from(p in "posts", order_by: ^[asc: dynamic([p], p.views + p.id)], select: p.id)|
            )

          built_first =
            fixture(~S"""
            key = dynamic([p], p.views + p.id)
            from(p in "posts", order_by: ^[asc: key], select: p.id)
            """)

          assert baseline(inline) == baseline(built_first)
          assert reached(inline, :arithmetic) == MapSet.new()

          assert reached(built_first, :arithmetic) ==
                   statements([
                     from(p in "posts", order_by: [asc: p.views - p.id], select: p.id)
                   ])
        end
      end

      # ── stage drops: a weakened query, or a broken dependency ───────────────────────────────

      describe "Stage drop — a stage nothing later requires drops to a weaker query" do
        test "a join only the row set depends on" do
          compiled =
            fixture(
              ~S'"posts" |> join(:inner, [p], c in "comments", on: c.post_id == p.id) |> select([p], p.id)'
            )

          assert dropped(compiled, ~r/^join\(/) ==
                   H.outcome(@repo, 0, fn -> from(p in "posts", select: p.id) end)
        end

        test "a join before another: the drop runs, with the later bindings shifted onto its slot" do
          compiled =
            fixture(~S"""
            "posts"
            |> join(:inner, [p], c in "comments", on: c.post_id == p.id)
            |> join(:inner, [p], a in "audit", on: a.post_id == p.id)
            |> where([p, c], c.score > 3)
            |> select([p], p.id)
            """)

          # `c` is the second binding, which is now the audit join.
          shifted =
            from(p in "posts",
              join: a in "audit",
              on: a.post_id == p.id,
              where: a.score > 3,
              select: p.id
            )

          assert dropped(compiled, ~r/^join\(:inner, \[p\], c in/) ==
                   H.outcome(@repo, 0, fn -> shifted end)
        end
      end

      describe "Stage drop — a stage a later one requires drops to no query at all" do
        # Each of these mutants is killed by any test that runs the query, whatever it asserts:
        # the kill shows that the stage is *executed*, not that its effect is pinned.
        test "a join whose binding a later stage reads — by position or by name" do
          positional =
            fixture(
              ~S'"posts" |> join(:inner, [p], c in "comments", on: c.post_id == p.id) |> select([p, c], {p.id, c.id})'
            )

          named =
            fixture(
              ~S'"posts" |> join(:inner, [p], c in "comments", as: :c, on: c.post_id == p.id) |> select([c: c], c.id)'
            )

          # Ecto counts positional bindings when it plans, and resolves a name as the stage builds.
          assert dropped(positional, ~r/^join\(/) == {:breaks, :plan}
          assert dropped(named, ~r/^join\(/) == {:breaks, :build}
        end

        test "the `limit` a `with_ties` qualifies" do
          compiled =
            fixture(
              ~S'"posts" |> order_by([p], p.id) |> limit(2) |> with_ties(true) |> select([p], p.id)'
            )

          assert dropped(compiled, ~r/^limit\(/) == {:breaks, :build}
        end

        test "the `windows` an `over/2` names" do
          compiled =
            fixture(
              ~S'"posts" |> windows([p], w: [partition_by: p.user_id]) |> select([p], over(count(p.id), :w))'
            )

          assert dropped(compiled, ~r/^windows\(/) == {:breaks, :plan}
        end

        test "the `with_cte` a join reads from" do
          compiled =
            fixture(~S"""
            "posts"
            |> with_cte("viewed", as: ^from(v in "posts", where: v.views > 5, select: %{id: v.id}))
            |> join(:inner, [p], v in "viewed", on: v.id == p.id)
            |> select([p], p.id)
            """)

          assert dropped(compiled, ~r/^with_cte\(/) == {:breaks, :run}
        end

        test "the `select` a schemaless source needs" do
          compiled = fixture(~S'"posts" |> select([p], p.id)')

          assert dropped(compiled, ~r/^select\(/) == {:breaks, :plan}
        end
      end
    end
  end
end
