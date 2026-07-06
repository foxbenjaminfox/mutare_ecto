defmodule Mutare.Ecto.ExoticQueryTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The exotic-Ecto surface: constructs beyond the everyday `from`/`where`/`select` diet —
  # window functions, CTEs, dynamic field access, JSON paths, VALUES lists, update queries,
  # lateral joins, subqueries in expression position, `selected_as` aliases, `with_ties`, and
  # friends. Each block pins *precisely* what the transform records (so a regression that starts
  # mutating a structural name, or stops offering a legitimate swap, fails loudly) and that the
  # rendered metamutant still compiles (the single-build net). Where a construct's interior is
  # deliberately left raw, the test documents the boundary it sits behind.
  #
  # `@all` turns every family on (including the opt-in literal arms) under the widest dialect
  # set — the harshest configuration, where a structural name wrongly classified as data would
  # produce a broken mutant.

  @all [
    mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: :all, dialects: [:postgres, :mysql]}]
  ]

  defp mutated(diffs), do: Enum.map(diffs, fn {_original, mutated} -> mutated end)

  describe "window functions (windows/over)" do
    test "a windows: definition and a named-window over/2 are left untouched" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            windows: [w: [partition_by: p.user_id, order_by: p.views]],
            select: %{id: p.id, rank: over(row_number(), :w)}
        end
      end
      """

      # The window definition is DSL data of an unhosted clause key (kept raw), the window
      # *name* is structural, and `row_number()` has no principled swap — nothing to mutate.
      assert ecto_diffs(src, @all) == []
      assert_compiles(src, @all)
    end

    test "an aggregate inside an inline over/2 gets its swap; the partition definition stays" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            select: %{total: over(sum(p.views), partition_by: p.user_id, order_by: p.views)}
        end
      end
      """

      assert {"from(p in MyApp.Post,\n  select: %{total: over(sum(p.views), partition_by: p.user_id, order_by: p.views)}\n)",
              "from(p in MyApp.Post,\n  select: %{total: over(avg(p.views), partition_by: p.user_id, order_by: p.views)}\n)"} in ecto_diffs(
               src,
               @all
             )

      assert_compiles(src, @all)
    end
  end

  describe "CTEs (with_cte / recursive_ctes)" do
    @cte_src """
    defmodule Q do
      import Ecto.Query

      def q do
        popular = from(p in MyApp.Post, where: p.views > 10)

        MyApp.Post
        |> recursive_ctes(true)
        |> with_cte("popular", as: ^popular)
        |> join(:inner, [p], c in "popular", on: c.id == p.id)
        |> where([p, c], p.views > 5)
      end
    end
    """

    test "the CTE's interior query is mutated where it is built, and each stage drops" do
      diffs = ecto_diffs(@cte_src, @all)

      # The CTE interior is an ordinary query expression — full comparison/literal treatment.
      assert {"p.views > 10", "p.views >= 10"} in diffs
      assert {"p.views > 10", "p.views > 11"} in diffs

      # Pipeline stages drop one at a time: the CTE attachment, the join, and the where.
      assert {"with_cte(\"popular\", as: ^popular)", "Elixir.Function.identity()"} in diffs

      assert {"join(:inner, [p], c in \"popular\", on: c.id == p.id)",
              "Elixir.Function.identity()"} in diffs

      assert {"where([p, c], p.views > 5)", "Elixir.Function.identity()"} in diffs

      # The join's on: condition and the outer where are mutated as usual; the recursive_ctes
      # toggle is never touched (flipping the flag is a broken query, not a mutant).
      assert {"c.id == p.id", "c.id != p.id"} in diffs
      assert {"p.views > 5", "p.views >= 5"} in diffs
      refute Enum.any?(mutated(diffs), &(&1 =~ "recursive_ctes(false)"))
    end

    test "the CTE metamutant compiles (a dropped with_cte surfaces at runtime, not build time)" do
      assert_compiles(@cte_src, @all)
    end
  end

  describe "field/2 dynamic column access" do
    test "the column-name atom is structural — never mutated, even with :atom_literal on" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(col) do
          from p in MyApp.Post,
            where: field(p, :views) > 10 and field(p, ^col) < 100
        end
      end
      """

      diffs = ecto_diffs(src, @all)

      # `field(p, :mutare)` would be a wrong (usually nonexistent) column, not a live mutant.
      refute Enum.any?(mutated(diffs), &(&1 =~ ":mutare"))

      # Both comparisons still swap around the field accesses, static and pinned alike.
      assert {"field(p, :views) > 10 and field(p, ^col) < 100",
              "field(p, :views) >= 10 and field(p, ^col) < 100"} in diffs

      assert {"field(p, :views) > 10 and field(p, ^col) < 100",
              "field(p, :views) > 10 and field(p, ^col) <= 100"} in diffs

      assert {"field(p, :views) > 10 and field(p, ^col) < 100",
              "field(p, :views) > 10 or field(p, ^col) < 100"} in diffs

      assert_compiles(src, @all)
    end
  end

  describe "selected_as select aliases" do
    @selected_as_src """
    defmodule Q do
      import Ecto.Query

      def q do
        from p in MyApp.Post,
          group_by: p.user_id,
          select: %{user: p.user_id, total: selected_as(sum(p.views), :total)},
          having: selected_as(:total) > 2
      end
    end
    """

    test "the alias name is structural in both arities; the aggregate and comparison still swap" do
      diffs = ecto_diffs(@selected_as_src, @all)

      # `selected_as(:mutare)` would reference an unknown alias — structural, never mutated.
      refute Enum.any?(mutated(diffs), &(&1 =~ ":mutare"))

      # The hosted having condition swaps around the alias reference…
      assert {"selected_as(:total) > 2", "selected_as(:total) >= 2"} in diffs
      assert {"selected_as(:total) > 2", "selected_as(:total) > 3"} in diffs
      # …and the select-side aggregate swaps inside the alias definition.
      assert {"from(p in MyApp.Post,\n  group_by: p.user_id,\n  select: %{user: p.user_id, total: selected_as(sum(p.views), :total)},\n  having: selected_as(:total) > 2\n)",
              "from(p in MyApp.Post,\n  group_by: p.user_id,\n  select: %{user: p.user_id, total: selected_as(avg(p.views), :total)},\n  having: selected_as(:total) > 2\n)"} in diffs

      assert_compiles(@selected_as_src, @all)
    end
  end

  describe "named bindings as structural names (as/parent_as)" do
    test "a correlated-subquery condition swaps; binding names are never mutated" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from u in MyApp.User,
            as: :u,
            where: as(:u).age > 21 and
                     exists(from p in MyApp.Post, where: p.user_id == parent_as(:u).id)
        end
      end
      """

      diffs = ecto_diffs(src, @all)

      # `as(:mutare)`/`parent_as(:mutare)` are unknown-binding errors, not mutants.
      refute Enum.any?(mutated(diffs), &(&1 =~ ":mutare"))

      assert {"as(:u).age > 21 and\n  exists(from(p in MyApp.Post, where: p.user_id == parent_as(:u).id))",
              "as(:u).age >= 21 and\n  exists(from(p in MyApp.Post, where: p.user_id == parent_as(:u).id))"} in diffs

      assert {"as(:u).age > 21 and\n  exists(from(p in MyApp.Post, where: p.user_id == parent_as(:u).id))",
              "as(:u).age > 21 and\n  not exists(from(p in MyApp.Post, where: p.user_id == parent_as(:u).id))"} in diffs

      assert_compiles(src, @all)
    end
  end

  describe "JSON access" do
    @json_src """
    defmodule Q do
      import Ecto.Query

      def q do
        from p in MyApp.Post,
          where: p.title["meta"]["kind"] == "news",
          select: json_extract_path(p.title, ["a", "b"])
      end
    end
    """

    test "path keys are data under the opt-in :string_literal arm (off by default)" do
      # Default configuration: the string arms are opt-in, so only the operator swap and the
      # clause drop fire — no path key (or comparison value) is touched.
      default_diffs = ecto_diffs(@json_src)

      assert {~s|p.title["meta"]["kind"] == "news"|, ~s|p.title["meta"]["kind"] != "news"|} in default_diffs

      refute Enum.any?(mutated(default_diffs), &(&1 =~ "mutare"))

      # With :string_literal enabled, a bracket key mutates like any in-fragment string — the
      # mutant selects a different JSON path, which differs exactly on rows carrying the
      # original key (killable, though noisy — why the arm is opt-in).
      all_diffs = ecto_diffs(@json_src, @all)

      assert {~s|p.title["meta"]["kind"] == "news"|, ~s|p.title["mutare"]["kind"] == "news"|} in all_diffs

      assert {~s|p.title["meta"]["kind"] == "news"|, ~s|p.title["meta"]["kind"] == "mutare"|} in all_diffs

      assert_compiles(@json_src, @all)
    end

    test "a json_extract_path select value is left raw (select paths are not conditions)" do
      # Every recorded mutant keeps the select path verbatim (only the where mutates).
      for m <- mutated(ecto_diffs(@json_src, @all)), m =~ "json_extract_path" do
        assert m =~ "json_extract_path(p.title, [\"a\", \"b\"])"
      end
    end
  end

  describe "filter/2 on aggregates" do
    test "the filter condition and the outer comparison both swap" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            group_by: p.user_id,
            having: filter(count(p.id), p.views > 10) > 5,
            select: p.user_id
        end
      end
      """

      diffs = ecto_diffs(src)

      assert {"filter(count(p.id), p.views > 10) > 5", "filter(count(p.id), p.views >= 10) > 5"} in diffs

      assert {"filter(count(p.id), p.views > 10) > 5", "filter(count(p.id), p.views > 10) >= 5"} in diffs

      assert {"filter(count(p.id), p.views > 10) > 5", "filter(count(p.id), p.views > 10) > 6"} in diffs

      assert_compiles(src, @all)
    end
  end

  describe "values/2 lists" do
    @values_src """
    defmodule Q do
      import Ecto.Query

      def q do
        from v in values([%{id: 1, views: 10}], %{id: :integer, views: :integer}),
          where: v.views > 5,
          select: v.id
      end
    end
    """

    test "the entries and types stay raw; the query around them mutates as usual" do
      diffs = ecto_diffs(@values_src, @all)

      assert {"v.views > 5", "v.views > 6"} in diffs
      assert {"v.views > 5", "v.views >= 5"} in diffs

      # Every recorded mutant keeps the VALUES data verbatim (the source position is skipped).
      values_call = "values([%{id: 1, views: 10}], %{id: :integer, views: :integer})"

      for {_original, m} <- diffs, m =~ "values(" do
        assert m =~ values_call
      end
    end

    test "core mutators do not splice into the values/2 DSL arguments (no poisoned build)" do
      opts = [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo, families: :all}]]
      diffs = diffs(@values_src, opts)

      # Core's only contribution is the whole-def return-value family; nothing reaches inside
      # the values(...) data, and the single build stays healthy.
      core = Enum.reject(diffs, fn {mutator, _o, _m} -> mutator == :ecto end)
      assert Enum.all?(core, fn {mutator, _o, _m} -> mutator == :return_value end)

      assert_compiles(@values_src, opts)
    end
  end

  describe "update queries (update_all/delete_all)" do
    @update_src """
    defmodule Q do
      import Ecto.Query

      def bump do
        from(p in MyApp.Post,
          where: p.views > 10,
          update: [inc: [views: 1], set: [published: true]]
        )
        |> MyApp.Repo.update_all([])
      end

      def wipe do
        from(p in MyApp.Post, where: p.views < 1) |> MyApp.Repo.delete_all()
      end
    end
    """

    test "the filters mutate; the update: instructions stay raw" do
      diffs = ecto_diffs(@update_src, @all)

      assert {"p.views > 10", "p.views >= 10"} in diffs
      assert {"p.views < 1", "p.views <= 1"} in diffs

      # The update instructions are write *payload*, not a filter — every mutant keeps them
      # verbatim (an inc/set literal bump would mutate what gets written, a mutation family
      # this plugin deliberately does not own at the DSL level).
      update_instr = "update: [inc: [views: 1], set: [published: true]]"

      for {_original, m} <- diffs, m =~ "update:" do
        assert m =~ update_instr
      end

      assert_compiles(@update_src, @all)
    end

    test "update_all/delete_all themselves are not persistence-swap targets" do
      # :persistence rewrites insert/update/delete (the changeset path, where apply_action is
      # a faithful dry-run). update_all/delete_all have no changeset to apply — no swap.
      refute Enum.any?(ecto_diffs(@update_src, @all), fn {_o, m} -> m =~ "apply_action" end)
    end
  end

  describe "cross and lateral joins" do
    @lateral_src """
    defmodule Q do
      import Ecto.Query

      def q do
        from p in MyApp.Post,
          as: :p,
          cross_join: u in MyApp.User,
          inner_lateral_join:
            t in subquery(
              from(p2 in MyApp.Post,
                where: p2.user_id == parent_as(:p).user_id,
                select: p2.views
              )
            ),
          as: :t,
          where: p.views > 1
      end
    end
    """

    test "cross/lateral joins get no join-type swap even under the widest dialects" do
      diffs = ecto_diffs(@lateral_src, @all)
      mutated = mutated(diffs)

      # A cross join has no on-condition to preserve across an inner↔left flip, and a lateral
      # join's laterality is not a cardinality knob — neither key swaps.
      refute Enum.any?(mutated, &(&1 =~ "left_join:"))
      refute Enum.any?(mutated, &(&1 =~ "left_lateral_join:"))

      # The ordinary where still mutates.
      assert {"p.views > 1", "p.views >= 1"} in diffs

      assert_compiles(@lateral_src, @all)
    end
  end

  describe "hints and prefixes" do
    test "hints:/prefix:/{prefix, Schema} are untouched even with the string arm on" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            hints: ["INDEXED BY posts_idx"],
            prefix: "main",
            where: p.views > 1
        end

        def q2 do
          from p in {"legacy_posts", MyApp.Post}, where: p.views > 1
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # Hint text, prefix names, and the source-table override are all structural SQL naming;
      # a mutated one is a broken query, never a live mutant.
      for m <- mutated do
        refute m =~ "mutare"

        if m =~ "hints:", do: assert(m =~ "INDEXED BY posts_idx")
        if m =~ "prefix:", do: assert(m =~ "prefix: \"main\"")
        if m =~ "legacy", do: assert(m =~ "{\"legacy_posts\", MyApp.Post}")
      end

      assert {"p.views > 1", "p.views >= 1"} in diffs
      assert_compiles(src, @all)
    end
  end

  describe "subqueries in expression position" do
    test "value-wrapper subqueries (all/any/subquery) mutate the outer operator AND the interior" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            where: p.views >= all(from p2 in MyApp.Post, select: max(p2.views))
        end

        def q2 do
          from p in MyApp.Post,
            where: p.views < any(from p2 in MyApp.Post, where: p2.views > 5, select: p2.views)
        end

        def q3 do
          from p in MyApp.Post,
            where: p.views > subquery(from p2 in MyApp.Post, select: avg(p2.views))
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # The outer operator still swaps (unchanged).
      assert Enum.any?(mutated, &(&1 =~ "p.views > all("))
      assert Enum.any?(mutated, &(&1 =~ "p.views <= any("))
      assert Enum.any?(mutated, &(&1 =~ "p.views >= subquery("))

      # Under a value-wrapper the projected `select` IS the observed value, so its aggregate swaps
      # now surface — `max`→`min` under `all`, `avg`→`sum` under `subquery`.
      assert Enum.any?(mutated, &(&1 =~ "min(p2.views)"))
      assert Enum.any?(mutated, &(&1 =~ "sum(p2.views)"))

      # …and the interior `where` condition mutates too — a row-set change every wrapper observes.
      assert Enum.any?(mutated, &(&1 =~ "p2.views >= 5"))

      assert_compiles(src, @all)
    end

    test "an exists interior mutates its condition/filter, but not its (unobserved) select" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from u in MyApp.User,
            as: :u,
            where: exists(from p in MyApp.Post, where: p.views > 10, select: max(p.views))
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # The whole-predicate polarity flip (unchanged).
      assert Enum.any?(mutated, &(&1 =~ ~r/\Anot exists\(from/))

      # The inner `where` condition mutates — a row-set change EXISTS observes…
      assert Enum.any?(mutated, &(&1 =~ "p.views >= 10"))
      assert Enum.any?(mutated, &(&1 =~ "p.views > 11"))
      # …as does dropping the inner filter entirely (the `where` gone, the rest kept).
      assert Enum.any?(mutated, &(&1 =~ ~r/exists\(from\(p in MyApp\.Post, select: max/))

      # But SQL never evaluates an EXISTS subquery's select list, so mutating it there is
      # unconditionally equivalent — suppressed, exactly like an `is_nil` interior. No `min`.
      refute Enum.any?(mutated, &(&1 =~ "min(p.views)"))

      assert_compiles(src, @all)
    end

    test "an inner join-type swaps under a subquery wrapper" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from u in MyApp.User,
            where:
              exists(
                from p in MyApp.Post,
                  join: c in MyApp.Post,
                  on: c.user_id == p.user_id,
                  where: p.views > 0
              )
        end
      end
      """

      mutated = mutated(ecto_diffs(src, @all))

      # The subquery's own join is a row-set knob EXISTS observes — inner↔left surfaces.
      assert Enum.any?(mutated, &(&1 =~ "left_join:"))

      assert_compiles(src, @all)
    end

    test "subquery interiors nest — an exists inside a subquery's own where still mutates" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from u in MyApp.User,
            as: :u,
            where:
              exists(
                from p in MyApp.Post,
                  where: exists(from c in MyApp.Post, where: c.views > 3)
              )
        end
      end
      """

      mutated = mutated(ecto_diffs(src, @all))

      # The doubly-nested condition mutates — the recursion re-enters Fragment at each level.
      assert Enum.any?(mutated, &(&1 =~ "c.views >= 3"))

      assert_compiles(src, @all)
    end

    test "a pin inside a subquery's condition is sub-contracted to core (not the SQL catalog)" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(threshold) do
          from u in MyApp.User,
            as: :u,
            where: exists(from p in MyApp.Post, where: p.views > ^(threshold + 1))
        end
      end
      """

      # With core's own families in play, the pin's *interior* Elixir (`threshold + 1`) is mutated
      # by core (arithmetic), delivered through the host's weave — while the SQL `>` stays ours.
      opts = [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo, families: :all}]]
      all_mutated = for {_mutator, _original, m} <- diffs(src, opts), do: m

      assert Enum.any?(all_mutated, &(&1 =~ "threshold - 1"))
      assert_compiles(src, opts)
    end

    test "a subquery source is mutated where the query is built, not inline" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          base = from p in MyApp.Post, where: p.views > 10
          from s in subquery(base), select: s.id
        end

        def q2 do
          from s in subquery(from p in MyApp.Post, where: p.views > 100), select: s.id
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # `base` is an ordinary from — fully mutated where it is built…
      assert {"p.views > 10", "p.views >= 10"} in diffs
      # …while the inline subquery source sits inside the from's skipped source position, so
      # its interior is out of reach. (The from-source is routed :skip wholesale; the idiomatic
      # build-then-wrap form above is how a subquery's interior earns mutants.)
      refute Enum.any?(mutated, &(&1 =~ "p.views >= 100"))
      refute Enum.any?(mutated, &(&1 =~ "p.views > 101"))

      assert_compiles(src, @all)
    end
  end

  describe "query manipulation functions" do
    test "exclude/2 and has_named_binding?/2 are not mutation targets" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(base) do
          base |> exclude(:order_by) |> exclude(:limit)
        end

        def q2(base) do
          if has_named_binding?(base, :p), do: base, else: from(p in base, as: :p)
        end
      end
      """

      # Mutating exclude's clause-name atom would silently stop excluding — a plausible but
      # structural change; the plugin leaves query-manipulation functions alone.
      assert ecto_diffs(src) == []
      assert_compiles(src, @all)
    end
  end

  describe "dynamic composition" do
    test "a dynamic built from other dynamics swaps its connective; each leaf swaps too" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(min, max) do
          d1 = dynamic([p], p.views > ^min)
          d2 = dynamic([p], p.views < ^max)
          combined = dynamic([p], ^d1 and ^d2)
          from p in MyApp.Post, where: ^combined
        end
      end
      """

      diffs = ecto_diffs(src)

      assert {"dynamic([p], ^d1 and ^d2)", "dynamic([p], ^d1 or ^d2)"} in diffs
      assert {"dynamic([p], p.views > ^min)", "dynamic([p], p.views >= ^min)"} in diffs
      assert {"dynamic([p], p.views < ^max)", "dynamic([p], p.views <= ^max)"} in diffs

      assert_compiles(src, @all)
    end
  end

  describe "union_all" do
    test "union/union_all get no combination swap (no principled complement) but filters mutate" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          recent = from p in MyApp.Post, where: p.views > 100
          from(p in MyApp.Post, where: p.published == true, union_all: ^recent)
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      refute Enum.any?(mutated, &(&1 =~ "union:"))
      refute Enum.any?(mutated, &(&1 =~ "except"))
      refute Enum.any?(mutated, &(&1 =~ "intersect"))

      assert {"p.views > 100", "p.views >= 100"} in diffs
      assert {"p.published == true", "p.published != true"} in diffs

      assert_compiles(src, @all)
    end
  end

  describe "interpolated whole clauses" do
    test "an interpolated order_by keyword list is core's business, not the plugin's" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post, order_by: ^[asc: :views, desc: :id]
        end
      end
      """

      assert ecto_diffs(src, @all) == []
      assert_compiles(src, @all)
    end
  end

  describe "map/2 and struct/2 selects" do
    test "field-list selects are shape declarations — nothing to mutate" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post, select: map(p, [:id, :views])
        end

        def q2 do
          from p in MyApp.Post, select: struct(p, [:id, :title])
        end
      end
      """

      assert ecto_diffs(src, @all) == []
      assert_compiles(src, @all)
    end
  end

  describe "fragment interpolation helpers (identifier/literal/splice)" do
    test "the helper calls stay raw while the surrounding condition mutates" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(col, vals) do
          from p in MyApp.Post,
            where: fragment("? > 10", identifier(^col)) and
                     fragment("? IN ?", p.views, splice(^vals)),
            select: fragment("count(?)", literal(^col))
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # Connective swap between the fragments; the fragments themselves (template + helper
      # pins) are untouched — the template is structural and the pins are core's islands.
      assert {~s|fragment("? > 10", identifier(^col)) and\n  fragment("? IN ?", p.views, splice(^vals))|,
              ~s|fragment("? > 10", identifier(^col)) or\n  fragment("? IN ?", p.views, splice(^vals))|} in diffs

      for m <- mutated do
        if m =~ "identifier", do: assert(m =~ "identifier(^col)")
        if m =~ "splice", do: assert(m =~ "splice(^vals)")
      end

      assert_compiles(src, @all)
    end
  end

  describe "keyword-form fragment" do
    test "the keyword grammar is the fragment's own — its interior stays raw" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            where: fragment(title: [foo: "bar"]) == true
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # Only the surrounding condition mutates (the == swap and, under the opt-in arm, the
      # boolean flip) — never the "bar" inside the fragment's private keyword grammar.
      assert {~s|fragment(title: [foo: "bar"]) == true|,
              ~s|fragment(title: [foo: "bar"]) != true|} in diffs

      refute Enum.any?(mutated, &(&1 =~ "foo: \"\""))
      refute Enum.any?(mutated, &(&1 =~ "foo: \"mutare\""))

      assert_compiles(src, @all)
    end
  end

  describe "type/2 with composite types" do
    test "a composite cast type is structural whatever its shape" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(ids, min) do
          from p in MyApp.Post,
            where: p.id in type(^ids, {:array, :integer}) and p.views > type(^min, :integer)
        end
      end
      """

      diffs = ecto_diffs(src, @all)

      assert {"p.id in type(^ids, {:array, :integer}) and p.views > type(^min, :integer)",
              "p.id not in type(^ids, {:array, :integer}) and p.views > type(^min, :integer)"} in diffs

      assert {"p.id in type(^ids, {:array, :integer}) and p.views > type(^min, :integer)",
              "p.id in type(^ids, {:array, :integer}) and p.views >= type(^min, :integer)"} in diffs

      refute Enum.any?(mutated(diffs), &(&1 =~ ":mutare"))

      assert_compiles(src, @all)
    end
  end

  describe "group_by/distinct expressions" do
    test "grouping and distinctness declarations are never mutated" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            group_by: [p.user_id, fragment("date(?)", p.title)],
            distinct: [asc: p.views],
            select: p.user_id
        end
      end
      """

      # A mutated group key changes every aggregate's meaning at once (a shotgun, not a probe),
      # and DISTINCT ON ordering is tied to the group shape — both stay raw by design.
      assert ecto_diffs(src, @all) == []
      assert_compiles(src, @all)
    end
  end

  describe "preload" do
    test "a pinned preload query mutates where it is built; a join preload rides the join" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          posts_query = from p in MyApp.Post, where: p.published == true, order_by: p.views
          from u in MyApp.User, preload: [posts: ^posts_query]
        end

        def q2 do
          from u in MyApp.User,
            left_join: p in assoc(u, :posts),
            where: p.views > 3,
            preload: [posts: p]
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # The standalone preload query gets full treatment where it is built…
      assert {"p.published == true", "p.published != true"} in diffs
      # …the join-preload's join narrows kind, and its filter mutates…
      assert {"from(u in MyApp.User,\n  left_join: p in assoc(u, :posts),\n  where: p.views > 3,\n  preload: [posts: p]\n)",
              "from(u in MyApp.User,\n  inner_join: p in assoc(u, :posts),\n  where: p.views > 3,\n  preload: [posts: p]\n)"} in diffs

      assert {"p.views > 3", "p.views >= 3"} in diffs
      # …while the preload declaration itself (which associations to load) stays raw: every
      # mutant that still carries a preload carries it verbatim.
      for m <- mutated, m =~ "preload" do
        assert m =~ "preload: [posts: ^posts_query]" or m =~ "preload: [posts: p]"
      end

      assert_compiles(src, @all)
    end
  end

  describe "bound literal forms" do
    test "hex and underscored bounds bump by value and report the written original" do
      # `AST.int_value` reads the token's *value* (10, 1000); the diff's original side keeps the
      # *written* form, and the weave's baseline branch re-emits the token verbatim — the
      # reads-through-`int_value`/emits-through-`Mutare.AST.literal` convention at the seam.
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            limit: 0x0A,
            offset: 1_000,
            select: p.id
        end
      end
      """

      diffs = ecto_diffs(src, @all)

      assert {"0x0A", "11"} in diffs
      assert {"0x0A", "9"} in diffs
      assert {"1_000", "1001"} in diffs
      assert {"1_000", "999"} in diffs

      mm = metamutant(src, @all)
      assert mm =~ "0x0A"
      assert mm =~ "1_000"

      assert_compiles(src, @all)
    end
  end

  describe "with_ties" do
    test "dropping a limit takes its with_ties along (the pair is one syntactic unit)" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post,
            order_by: [desc: p.views],
            limit: 3,
            with_ties: true
        end
      end
      """

      diffs = ecto_diffs(src, @all)
      mutated = mutated(diffs)

      # The bound drop removes limit AND with_ties — a dangling `with_ties:` fails Ecto's
      # expansion-time adjacency check and would poison the whole metamutant build.
      drop = Enum.find(mutated, &(&1 =~ "from" and not (&1 =~ "limit")))
      assert drop
      refute drop =~ "with_ties"

      # The off-by-one bumps are hosted pin-only (bare-integer diffs), so the limit/with_ties
      # pair — and the whole query — stays intact around the woven selector.
      assert {"3", "4"} in diffs
      assert {"3", "2"} in diffs

      # The single-build net: this exact shape used to fail to compile.
      assert_compiles(src, @all)
    end

    test "a pinned limit with with_ties still drops as a pair and compiles" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q(n) do
          from p in MyApp.Post,
            order_by: [desc: p.views],
            limit: ^n,
            with_ties: true
        end
      end
      """

      mutated = mutated(ecto_diffs(src, @all))
      drop = Enum.find(mutated, &(&1 =~ "from" and not (&1 =~ "limit")))
      assert drop
      refute drop =~ "with_ties"

      assert_compiles(src, @all)
    end

    test "the standalone pipe form drops each stage independently and still compiles" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          MyApp.Post
          |> order_by([p], desc: p.views)
          |> limit(3)
          |> with_ties(true)
        end
      end
      """

      diffs = ecto_diffs(src, @all)

      # Standalone with_ties/2 validates at query-build time, not expansion time — so the
      # limit-stage drop compiles (the dangling with_ties mutant dies at runtime instead).
      assert {"limit(3)", "Elixir.Function.identity()"} in diffs
      assert {"with_ties(true)", "Elixir.Function.identity()"} in diffs

      assert_compiles(src, @all)
    end
  end

  describe "negated conditions" do
    test "a not-wrapped comparison mutates inside the negation without double-wrapping" do
      src = """
      defmodule Q do
        import Ecto.Query

        def q do
          from p in MyApp.Post, where: not (p.views > 10)
        end
      end
      """

      diffs = ecto_diffs(src)

      assert {"not (p.views > 10)", "not (p.views >= 10)"} in diffs
      assert {"not (p.views > 10)", "not (p.views > 11)"} in diffs
      refute Enum.any?(mutated(diffs), &(&1 =~ "not not"))

      assert_compiles(src, @all)
    end
  end
end
