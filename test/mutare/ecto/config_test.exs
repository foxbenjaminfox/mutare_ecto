defmodule Mutare.Ecto.ConfigTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Milestone 4 configuration: narrowing the catalog with `families:`, gating dialect-specific
  # mutations with `dialects:`, reporting a sub-family under its own name with `:as`, and covering
  # several repos by listing the plugin more than once.

  defp ecto(opts), do: [mutators: [{Mutare.Ecto, [repo: MyApp.Repo] ++ opts}]]
  defp mutated(diffs), do: Enum.map(diffs, fn {_o, m} -> m end)

  describe "families: narrows the catalog" do
    @src """
    defmodule M do
      import Ecto.Query
      def q, do: from(u in User, where: u.age > 18, select: u.id)
    end
    """

    test "a single in-fragment family keeps only its mutants" do
      # :comparison → just the boundary swap (no fragment-literal bumps, no filter drop).
      assert ecto_diffs(@src, ecto(families: [:comparison])) == [{"u.age > 18", "u.age >= 18"}]

      # :fragment_literal → just the literal bumps.
      lit = mutated(ecto_diffs(@src, ecto(families: [:fragment_literal])))
      assert Enum.sort(lit) == Enum.sort(["u.age > 19", "u.age > 17", "u.age > 0"])
    end

    test "a single whole-from family keeps only its mutants" do
      # :filter_drop → just the where-drop (a whole-`from` rewrite), no in-fragment swaps.
      drops = ecto_diffs(@src, ecto(families: [:filter_drop]))
      assert [{_original, mutated}] = drops
      assert mutated =~ "from(" and not (mutated =~ "u.age")
    end

    test ":all (the default) yields every family" do
      all = mutated(ecto_diffs(@src))
      assert "u.age >= 18" in all
      assert "u.age > 19" in all
      assert Enum.any?(all, &(&1 =~ "from(" and not (&1 =~ "u.age")))
    end
  end

  describe "dialects: gates non-portable mutations" do
    test "left↔right join only under a RIGHT-capable dialect" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in Post, left_join: c in assoc(p, :comments), on: c.ok, select: p.id
        end
      end
      """

      # Portable default: left_join → inner_join only.
      portable = mutated(ecto_diffs(src, ecto(families: [:join_type])))
      assert Enum.any?(portable, &(&1 =~ "inner_join: c in assoc"))
      refute Enum.any?(portable, &(&1 =~ "right_join"))

      # Postgres: adds left_join → right_join.
      pg = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [:postgres])))
      assert Enum.any?(pg, &(&1 =~ "inner_join: c in assoc"))
      assert Enum.any?(pg, &(&1 =~ "right_join: c in assoc"))
    end

    test "*→full join only under a FULL-capable dialect" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in Post, left_join: c in assoc(p, :comments), on: c.ok, select: p.id
        end
      end
      """

      # Portable default and a RIGHT-only dialect never introduce a FULL join.
      portable = mutated(ecto_diffs(src, ecto(families: [:join_type])))
      refute Enum.any?(portable, &(&1 =~ "full_join"))

      mysql = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [:mysql])))
      refute Enum.any?(mysql, &(&1 =~ "full_join"))

      # Postgres and SQLite both support FULL JOIN: left_join → full_join is offered.
      for dialect <- [:postgres, :sqlite] do
        flips = mutated(ecto_diffs(src, ecto(families: [:join_type], dialects: [dialect])))

        assert Enum.any?(flips, &(&1 =~ "full_join: c in assoc")),
               "expected a full_join mutant under #{dialect}"
      end

      # The woven full_join branch is valid Ecto — the single build (every mutant) compiles.
      assert_compiles(src, ecto(families: [:join_type], dialects: [:postgres]))
    end
  end

  describe ":as reports a sub-family under its own name" do
    test "the recorded mutator is the :as name, not :ecto" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.x == u.y, select: u.id)
      end
      """

      diffs =
        diffs(src,
          mutators: [
            {Mutare.Ecto, repo: MyApp.Repo, families: [:comparison], as: :sql_comparison}
          ]
        )

      assert {:sql_comparison, "u.x == u.y", "u.x != u.y"} in diffs
      refute Enum.any?(diffs, fn {mutator, _o, _m} -> mutator == :ecto end)
    end
  end

  describe "equivalence-sensitive families + validation" do
    test "the helper lists the NULL/boundary three-valued families" do
      assert Mutare.Ecto.equivalence_sensitive_families() == [
               :comparison,
               :connective,
               :null_predicate,
               :ordering_nulls
             ]

      # …and they're a subset of the full set.
      assert Mutare.Ecto.equivalence_sensitive_families() -- Mutare.Ecto.families() == []
    end

    test "the full family set is exposed" do
      assert :comparison in Mutare.Ecto.families()
      assert :validation_drop in Mutare.Ecto.families()
      assert :persistence in Mutare.Ecto.families()
      assert :on_conflict in Mutare.Ecto.families()
      assert :query_terminal in Mutare.Ecto.families()
      assert :hook_drop in Mutare.Ecto.families()
      assert :ordering_nulls in Mutare.Ecto.families()
      assert :clause_drop in Mutare.Ecto.families()
      assert length(Mutare.Ecto.families()) == 18
    end

    test "an unknown family name fails loudly" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.x == u.y)
      end
      """

      assert_raise ArgumentError, ~r/unknown Mutare.Ecto families: \[:bogus\]/, fn ->
        ecto_diffs(src, ecto(families: [:bogus]))
      end
    end

    test "an equivalence-sensitive mutant carries the report note; an ordinary one does not" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(roles), do: from(u in User, where: u.x == u.y and u.role in ^roles, select: u.id)
      end
      """

      {_meta, sites, _next} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      # The comparison swap (== → !=) is equivalence-sensitive → the note rides onto the Site
      # and into the survivor header.
      comparison = Enum.find(sites, &(&1.mutated_code =~ "!=" and &1.mutator == :ecto))
      assert comparison.note == "kill may require NULL/boundary data (SQL three-valued logic)"
      assert Mutare.Report.header(comparison) =~ "SURVIVED  — kill may require NULL/boundary data"

      # The membership polarity flip (in → not in) is not equivalence-sensitive → no note.
      membership = Enum.find(sites, &(&1.mutated_code =~ "not in" and &1.mutator == :ecto))
      assert membership.note == nil
      assert Mutare.Report.header(membership) =~ ~r/SURVIVED$/
    end

    test "a non-hosted ordering_nulls mutant carries the note too (mutate/2 delivery)" do
      # `:ordering_nulls` is equivalence-sensitive but delivered in place via `mutate/2`, not the
      # host. Now that core accepts a `%Mutare.Mutator.Mutation{}` on the `mutate/2` return, its note
      # rides onto the Site just like the in-fragment families' — so the advisory surfaces for *every*
      # equivalence-sensitive family, not only the hosted three.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, order_by: [asc_nulls_first: u.score], select: u.id)
      end
      """

      {_meta, sites, _next} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      # The NULLs-placement flip (asc_nulls_first → asc_nulls_last) is the ordering_nulls mutant; the
      # direction flip (→ desc_nulls_first) is plain :ordering and carries no note.
      nulls = Enum.find(sites, &(&1.mutated_code =~ "asc_nulls_last" and &1.mutator == :ecto))
      assert nulls.note == "kill may require NULL/boundary data (SQL three-valued logic)"
      assert Mutare.Report.header(nulls) =~ "SURVIVED  — kill may require NULL/boundary data"

      direction =
        Enum.find(sites, &(&1.mutated_code =~ "desc_nulls_first" and &1.mutator == :ecto))

      assert direction.note == nil
    end
  end

  describe "multiple repos" do
    test "an aggregate is matched against each configured repo, under its own name" do
      src = """
      defmodule M do
        def a(q), do: Accounts.Repo.aggregate(q, :sum, :amount)
        def b(q), do: Billing.Repo.aggregate(q, :sum, :total)
      end
      """

      diffs =
        diffs(src,
          mutators: [
            {Mutare.Ecto, repo: Accounts.Repo, families: [:aggregate], as: :accounts},
            {Mutare.Ecto, repo: Billing.Repo, families: [:aggregate], as: :billing}
          ]
        )

      assert Enum.any?(diffs, fn {m, o, mut} ->
               m == :accounts and o =~ "Accounts.Repo" and o =~ ":sum" and mut =~ ":avg"
             end)

      assert Enum.any?(diffs, fn {m, o, mut} ->
               m == :billing and o =~ "Billing.Repo" and o =~ ":sum" and mut =~ ":avg"
             end)

      # Each repo's mutator only fires on its own Repo's call.
      assert Enum.count(diffs, fn {m, _o, _} -> m == :accounts end) == 1
      assert Enum.count(diffs, fn {m, _o, _} -> m == :billing end) == 1
    end
  end
end
