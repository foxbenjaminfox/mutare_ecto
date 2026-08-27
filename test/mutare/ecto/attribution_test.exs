defmodule Mutare.Ecto.AttributionTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The per-clause report-location adoption (`Mutare.Mutator.Mutation.at/2` / `at_drop/1`, wired
  # through `Mutare.Ecto.Query`). A **whole-`from` rewrite** — a clause drop, an order flip, a
  # join/set-op *key* swap, a `select`/`order_by` value swap, a source binding-reorder — is
  # *delivered* as a whole rebuilt `from(...)` spliced into the metamutant, but *reported* at the
  # specific inner clause it changed. So each mutant's Site line/column, diff, and (the payoff)
  # `# mutare:ignore` line land on that clause, not on the `from` opener where every whole-`from`
  # mutant used to collapse.
  #
  # This is the behaviour the diff-shape assertions elsewhere only prove *indirectly*: here we pin
  # the Site **line** for every whole-`from` family from one multi-line query, and — the headline —
  # that a directive on one clause suppresses only that clause's mutant while a same-family sibling
  # on another line keeps running. (The hosted `where`/`having` and `limit`/`offset`-bump families
  # were already per-clause; their line/ignore behaviour lives in `variant_test.exs`.)

  @mutators [{Mutare.Ecto, repo: MyApp.Repo, dialects: [:postgres]}]

  defp one(sites, pred) do
    case Enum.filter(sites, pred) do
      [site] ->
        site

      other ->
        flunk(
          "expected exactly one matching site, got #{length(other)}: " <>
            inspect(Enum.map(other, &{&1.line, &1.variant, &1.operation}))
        )
    end
  end

  describe "each whole-`from` family reports at its own clause line" do
    # from( is line 4; each clause sits on its own line 5..10.
    @src """
    defmodule M do
      import Ecto.Query
      def q(other) do
        from(p in Post,
          where: p.views > 1,
          where: p.likes > 2,
          order_by: [asc: p.title],
          left_join: c in assoc(p, :comments),
          limit: 10,
          intersect: ^other
        )
      end
    end
    """

    test "a clause drop lands on the dropped clause's line — each of two where:s independently" do
      sites = sites(@src, mutators: @mutators)

      drop1 = one(sites, &(&1.operation == :delete and &1.original_code == "p.views > 1"))
      drop2 = one(sites, &(&1.operation == :delete and &1.original_code == "p.likes > 2"))

      # Each lands on its own clause line (5 and 6), not collapsed onto the `from(` opener (line 4)
      # as they were before attribution — the exact-line asserts subsume any `!= 4` check.
      assert drop1.line == 5
      assert drop2.line == 6
    end

    test "the order flip, join-kind swap, bound drop, and set-op swap each land on their clause" do
      sites = sites(@src, mutators: @mutators)

      assert one(sites, &("ordering" in &1.variant)).line == 7

      # Both join-kind swaps (left→inner and, under :postgres, left→right) report at the join line.
      join_lines = for(s <- sites, "join_type" in s.variant, do: s.line) |> Enum.uniq()
      assert join_lines == [8]

      assert one(sites, &(&1.operation == :delete and &1.original_code == "10")).line == 9
      assert one(sites, &("combination" in &1.variant)).line == 10
    end

    test "the whole query still compiles when every mutant is woven in" do
      assert_compiles(@src, mutators: @mutators)
    end
  end

  describe "# mutare:ignore on one clause suppresses only that clause's whole-`from` mutant" do
    # The payoff. Before attribution both where: drops reported on the `from(` line, so a single
    # directive there could not distinguish them (and could only be placed on the opener at all).
    test "an ignore on the first where: leaves the second where:'s drop live" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(p in Post,
            where: p.views > 1, # mutare:ignore[ecto:filter_drop]
            where: p.likes > 2,
            select: p.id
          )
        end
      end
      """

      sites = sites(src, mutators: @mutators)

      ignored = one(sites, &(&1.operation == :delete and &1.original_code == "p.views > 1"))
      live = one(sites, &(&1.operation == :delete and &1.original_code == "p.likes > 2"))

      assert ignored.ignored, "the drop on the directive's clause line is suppressed"
      refute live.ignored, "the sibling where:'s drop on another line keeps running"
    end

    test "an ignore above the window's order_by suppresses only the window's coalesce drop" do
      # The scenario that motivated node-level attribution: one select stage carrying two
      # *textually identical* coalesce calls — a projected value and a window sort key. Same
      # family, same logical diff; before node-level attribution both Sites collapsed onto the
      # stage head, so no line-scoped directive could suppress one without also killing the
      # other, and no vocabulary could tell identical expressions apart — position is the only
      # discriminator.
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          select(query, [m], %{
            at: coalesce(m.timestamp, m.inserted_at),
            rank:
              over(row_number(),
                partition_by: m.hash,
                # mutare:ignore[ecto:coalesce] PG's DESC NULLS FIRST makes the fallback unobservable
                order_by: [desc: coalesce(m.timestamp, m.inserted_at), desc: m.id]
              )
          })
        end
      end
      """

      sites = sites(src, mutators: @mutators)

      window = one(sites, &("coalesce_in_ordering" in &1.variant))

      value =
        one(sites, &("coalesce" in &1.variant and "coalesce_in_ordering" not in &1.variant))

      # Node-level diffs — each Site names the coalesce call, not the whole select stage…
      assert value.original_code == "coalesce(m.timestamp, m.inserted_at)"
      assert value.mutated_code == "m.timestamp"
      assert window.original_code == value.original_code

      # …on their own lines: the at: projection and the window's order_by option.
      assert value.line == 6
      assert window.line == 11

      # The payoff: the directive above the window line reaches exactly the window's drop.
      assert window.ignored, "the window sort key's drop is suppressed"
      refute value.ignored, "the identical projected coalesce keeps running"

      # And each position reads its own equivalence note — the projection the NULL-data reason,
      # the sort key the engine-default-placement one.
      assert value.note =~ "the exact rows the default exists for"
      assert window.note =~ "default NULL placement"
    end

    test "on a shared line, [ecto:coalesce_in_ordering] tells identical drops apart by label" do
      # When both coalesces sit on one line, line-scoped attribution can't separate them — but
      # the ordering-position drop's finer label can: the qualifier matches only the window's.
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          select(query, [m], %{at: coalesce(m.a, m.b), rank: over(row_number(), order_by: [desc: coalesce(m.a, m.b)])}) # mutare:ignore[ecto:coalesce_in_ordering]
        end
      end
      """

      sites = sites(src, mutators: @mutators)

      assert one(sites, &("coalesce_in_ordering" in &1.variant)).ignored,
             "the window sort key's drop is suppressed"

      refute one(
               sites,
               &("coalesce" in &1.variant and "coalesce_in_ordering" not in &1.variant)
             ).ignored,
             "the projected coalesce on the same line keeps running"
    end

    test "a clause-level directive leaves the same clause's other-family mutants alone" do
      # `[ecto:filter_drop]` is family-specific: it kills only the drop, not the hosted comparison
      # or literal bumps that also anchor on that same clause line.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(p in Post,
            where: p.views > 1, # mutare:ignore[ecto:filter_drop]
            select: p.id
          )
        end
      end
      """

      sites = sites(src, mutators: @mutators)

      assert one(sites, &(&1.operation == :delete)).ignored, "the drop is suppressed"

      refute one(sites, &(&1.mutated_code == "p.views >= 1")).ignored,
             "the comparison swap survives"

      refute one(sites, &(&1.mutated_code == "p.views > 2")).ignored, "the literal bump survives"
    end
  end

  describe "a subquery interior's whole-`from` attribution follows the delivery path" do
    # `Mutare.Ecto.Subquery` composes `Query`'s producers into an inline subquery's `from`, and each
    # tag keeps the inner-clause attribution `Query` stamps. What happens to it depends on who
    # delivers: a free-standing `dynamic` is rewritten whole-call **in place**
    # (`Mutare.Ecto.Dynamic`), so the attribution is honoured and the drop lands on the inner
    # `where:` line (5), not the `dynamic` opener (4) — exactly as a top-level `from`'s would.
    @dynamic_src """
    defmodule M do
      import Ecto.Query
      def d do
        dynamic([p], p.views > subquery(from(c in MyApp.Post,
          where: c.likes > 1,
          select: max(c.views))))
      end
    end
    """

    # Through the host's weave the same tag's attribution is discarded structurally: a hosted Site
    # reports at the woven condition — here the outer `where:` line (5), not the inner one (6) —
    # as a `:replace` of that condition (the outer clause's own top-level drop is the `:delete`
    # sharing the line).
    @hosted_src """
    defmodule M do
      import Ecto.Query
      def q do
        from(p in MyApp.Post,
          where: p.views > subquery(from(c in MyApp.Post,
            where: c.likes > 1,
            select: max(c.views))))
      end
    end
    """

    test "in place (a free-standing dynamic), the inner filter drop lands on its own clause line" do
      drop = @dynamic_src |> sites(mutators: @mutators) |> one(&(&1.variant == ["filter_drop"]))
      assert {drop.line, drop.operation} == {5, :delete}
    end

    test "hosted (a from's where:), the inner filter drop reports at the woven condition" do
      drop =
        @hosted_src
        |> sites(mutators: @mutators)
        |> one(&(&1.variant == ["filter_drop"] and &1.operation == :replace))

      assert drop.line == 5
    end
  end
end
