defmodule Mutare.Ecto.EquivalenceTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The equivalence-sensitive families' report notes (`Mutare.Ecto.Equivalence`): each rides onto
  # its mutant's Site through the `finalize/2` funnel — on both delivery paths, the host's weave
  # and a plain `mutate/2` rewrite — phrased for the family's own equivalence reason.

  describe "equivalence notes" do
    test "an equivalence-sensitive mutant carries the report note; an ordinary one does not" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(roles), do: from(u in User, where: u.x == u.y and u.role in ^roles, select: u.id)
      end
      """

      sites = sites(src)

      # The comparison swap (== → !=) is equivalence-sensitive → the note rides onto the recorded
      # mutant (core renders it as the survivor header's trailing "— kill may require …").
      # `==`/`!=` reads the NULL-exclusion sub-case note, not the strict↔non-strict boundary one.
      comparison = Enum.find(sites, &(&1.mutated_code =~ "!=" and &1.mutator == :ecto))

      assert comparison.note ==
               "kill may require a non-NULL row — == and != differ on every concrete value but both exclude NULLs (compared as unknown), so they coincide only when every row is NULL"

      # The membership polarity flip (in → not in) is not equivalence-sensitive → no note.
      membership = Enum.find(sites, &(&1.mutated_code =~ "not in" and &1.mutator == :ecto))
      assert membership.note == nil
    end

    test "the != -> == direction reads the same NULL-exclusion note (finer tags the source operator)" do
      # `Equivalence.note/2`'s `"!="` guard arm is reached only when the *written* operator is
      # `!=` (swapped to `==`) — the finer label tags the source operator, not the mutated one
      # (`u.x == u.y` above only ever exercises the `"=="` arm). Written the other way round, the
      # same NULL-exclusion note must still apply.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.x != u.y, select: u.id)
      end
      """

      sites = sites(src)

      equality = Enum.find(sites, &(&1.mutated_code =~ "u.x == u.y" and &1.mutator == :ecto))

      assert equality.note ==
               "kill may require a non-NULL row — == and != differ on every concrete value but both exclude NULLs (compared as unknown), so they coincide only when every row is NULL"
    end

    test "the two comparison sub-cases carry different notes (boundary vs NULL exclusion)" do
      # A strict↔non-strict swap and an `==`/`!=` swap survive for *opposite* data reasons — a
      # missing boundary row versus a missing non-NULL row — so each reads its own note rather than
      # one shared "three-valued logic" string.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.age > 18 and u.role == u.name, select: u.id)
      end
      """

      sites = sites(src)

      # `>` → `>=` is the strict↔non-strict boundary swap.
      boundary = Enum.find(sites, &(&1.mutated_code =~ ">=" and &1.mutator == :ecto))
      assert boundary.note =~ "a row whose value sits exactly on the bound"

      # `==` → `!=` is the NULL-exclusion sub-case — a distinct note.
      equality = Enum.find(sites, &(&1.mutated_code =~ "!=" and &1.mutator == :ecto))
      assert equality.note =~ "a non-NULL row"

      refute boundary.note == equality.note
    end

    test "the two arithmetic sub-cases carry different notes (additive vs multiplicative identity)" do
      # `+`↔`-` survive when the right operand is always 0; `*`↔`/` when it is always ±1 (or the
      # left always 0) — different fixtures, so each sub-case reads its own note, resolved from the
      # finer operator label exactly as `:comparison`'s split is.
      src = """
      defmodule M do
        import Ecto.Query
        def q(v), do: from(u in User, where: u.a + u.b > ^v and u.a * u.b < ^v, select: u.id)
      end
      """

      sites = sites(src)

      additive = Enum.find(sites, &(&1.mutated_code =~ "u.a - u.b" and &1.mutator == :ecto))
      assert additive.note =~ "right operand is nonzero"

      multiplicative = Enum.find(sites, &(&1.mutated_code =~ "u.a / u.b" and &1.mutator == :ecto))
      assert multiplicative.note =~ "not ±1"

      refute additive.note == multiplicative.note
    end

    test "the two coalesce sub-cases carry different notes (NULL data vs engine-default placement)" do
      # A value-position drop survives only when no NULL row exists; an ordering-position drop
      # can also survive with NULL rows present, because the engine's *default* NULL placement
      # may coincide with where the fallback ranked them (Postgres sorts NULL as larger than
      # every value, SQLite/MySQL as smaller). Each position reads its own note, resolved from
      # the finer label exactly as `:comparison`'s and `:arithmetic`'s splits are.
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(u in User,
            order_by: [desc: coalesce(u.score, 0)],
            select: coalesce(u.score, 0)
          )
        end
      end
      """

      sites = sites(src)

      coalesce_sites = Enum.filter(sites, &(&1.mutator == :ecto and "coalesce" in &1.variant))
      ordering = Enum.find(coalesce_sites, &("coalesce_in_ordering" in &1.variant))
      value = Enum.find(coalesce_sites, &("coalesce_in_ordering" not in &1.variant))

      assert value.note =~ "the exact rows the default exists for"
      assert ordering.note =~ "default NULL placement"
      refute value.note == ordering.note
    end

    test "the / -> * direction reads the same multiplicative-identity note (finer tags the source operator)" do
      # Mirrors the comparison case above: the `"/"` guard arm is reached only when the *written*
      # operator is `/` (swapped to `*`) — the earlier test's `u.a * u.b` only ever exercises the
      # `"*"` arm.
      src = """
      defmodule M do
        import Ecto.Query
        def q(v), do: from(u in User, where: u.a / u.b < ^v, select: u.id)
      end
      """

      sites = sites(src)

      multiplicative = Enum.find(sites, &(&1.mutated_code =~ "u.a * u.b" and &1.mutator == :ecto))
      assert multiplicative.note =~ "not ±1"
    end

    test "a coalesce drop carries its NULL-data note on both delivery paths" do
      # The same family rides the host (a `where` coalesce) and the in-place `select` rewrite —
      # the note must surface on each, since either survivor may be an honest NULL-data gap.
      src = """
      defmodule M do
        import Ecto.Query

        def q(d) do
          from(u in User, where: coalesce(u.score, ^d) > 10, select: coalesce(u.rank, ^d))
        end
      end
      """

      sites = sites(src)

      hosted = Enum.find(sites, &(&1.mutated_code == "u.score > 10" and &1.mutator == :ecto))
      assert hosted.note =~ "NULL rows in the wrapped expression"

      # The in-place `select` rewrite now reports at the clause value: coalesce(u.rank, ^d) → u.rank.
      in_place =
        Enum.find(
          sites,
          &(&1.mutator == :ecto and &1.original_code == "coalesce(u.rank, ^d)" and
              &1.mutated_code == "u.rank")
        )

      assert in_place.note =~ "NULL rows in the wrapped expression"
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

      sites = sites(src)

      # The NULLs-placement flip (asc_nulls_first → asc_nulls_last) is the ordering_nulls mutant; the
      # direction flip (→ desc_nulls_first) is plain :ordering and carries no note.
      nulls = Enum.find(sites, &(&1.mutated_code =~ "asc_nulls_last" and &1.mutator == :ecto))

      assert nulls.note ==
               "kill may require NULL rows in the ordered column — nulls_first and nulls_last only change where NULLs sort, ordering all other rows identically"

      direction =
        Enum.find(sites, &(&1.mutated_code =~ "desc_nulls_first" and &1.mutator == :ecto))

      assert direction.note == nil
    end

    test "a join_type mutant carries the join-cardinality note (mutate/2 delivery)" do
      # `:join_type` is equivalence-sensitive for a *data* reason, not three-valued logic: the
      # LEFT↔INNER narrowing is equivalent whenever no orphan row exists (e.g. a mandatory FK). Its
      # note differs from the in-fragment families', and like `:ordering_nulls` it rides the
      # `mutate/2` whole-`from` rewrite, not the host.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(p in Post, left_join: c in assoc(p, :comments), on: c.ok, select: p.id)
      end
      """

      sites = sites(src)

      join = Enum.find(sites, &(&1.mutated_code =~ "inner_join" and &1.mutator == :ecto))

      assert join.note ==
               "kill may require an orphan row — a preserved-side row with no match (join kinds coincide when every row matches)"
    end

    test "the connective, null_predicate, and temporal notes each ride onto their own mutant" do
      # The remaining equivalence-sensitive families the other note tests don't pin: `:connective`
      # (`and`↔`or`), `:null_predicate` (`is_nil`↔`not is_nil`), and `:temporal` (`ago`↔`from_now`).
      # Each reads a *distinct* note, so a wrong family→note wiring would surface the wrong string —
      # pin a phrase unique to each.
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(u in User,
            where: u.active and is_nil(u.score) and u.joined_at > ago(1, "day"),
            select: u.id
          )
        end
      end
      """

      sites = sites(src)

      connective = Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ ~r/\bor\b/))
      assert connective.note =~ "the operands disagree"

      null_predicate =
        Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ "not is_nil(u.score)"))

      assert null_predicate.note =~ "complementary row sets"

      temporal = Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ "from_now"))
      assert temporal.note =~ "opposite sides of now"

      # …and a family that is *not* equivalence-sensitive (the `>` boundary swap here is, but the
      # membership-free condition carries no non-sensitive counterexample) — sanity-check that the
      # three notes are genuinely different from one another.
      assert connective.note != null_predicate.note
      assert null_predicate.note != temporal.note
    end

    test "finalize/2 resolves the equivalence note from the *first* finer label, not the last" do
      # No real producer currently emits more than one finer label for an equivalence-sensitive
      # family (`:comparison`'s is always a single operator string), so this is a contract pin, not
      # an observed-in-the-wild shape: construct a variant whose finer list disagrees between its
      # first (">",  the default boundary note) and last ("==", the NULL-exclusion note) label, and
      # confirm the first one wins.
      context = %{config: Mutare.Ecto.Config.parse!([])}
      mutation = Mutare.Mutator.Mutation.new(quote(do: 1 > 2), variant: [:comparison, ">", "=="])

      assert %Mutare.Mutator.Mutation{note: note} =
               Mutare.Ecto.Equivalence.finalize(mutation, context)

      assert note =~ "a row whose value sits exactly on the bound"
    end
  end
end
