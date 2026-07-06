defmodule Mutare.Ecto.VariantTest do
  use ExUnit.Case, async: true

  # `# mutare:ignore[ecto:<label>]` variant suppression. Every recorded mutant is tagged (via
  # `Mutare.Ecto.Config.tagged/1`) with its SQL **family** and, for a swap/value family, the finer
  # **operator/kind** it mutated — and `Mutare.Ecto.variants/0` declares the whole vocabulary. So a
  # qualified directive suppresses just one family *or* one operator at a site while its siblings keep
  # running (the per-site analogue of the run-wide `families:` filter, only finer). The tags ride both
  # delivery paths: the selector **host** (a hosted `where`/`having` condition) and a plain
  # **`mutate/2`** whole-`from` rewrite.

  @mutators [{Mutare.Ecto, repo: MyApp.Repo}]

  defp sites_for(src) do
    %Mutare.Transform.Result{mutants: sites} =
      Mutare.transform_string(src,
        file: "variant_fixture.ex",
        mutators: @mutators,
        expand_uses: true
      )

    sites
  end

  # The single `:ecto` site whose rendered mutant contains `substring`.
  defp site(sites, substring) do
    Enum.find(sites, &(&1.mutator == :ecto and &1.mutated_code =~ substring))
  end

  describe "variants/0 vocabulary" do
    test "covers every family plus the finer operator/kind labels" do
      variants = Mutare.Ecto.variants()

      # every SQL family is targetable...
      assert Enum.all?(Mutare.Ecto.families(), &(&1 in variants))

      # ...and so is each operator/value kind the swap and value families add — in-fragment
      # (comparison/connective/arithmetic/null-predicate/literal)...
      assert "<" in variants
      assert ">" in variants
      assert "and" in variants
      assert "+" in variants
      assert "/" in variants
      assert "coalesce" in variants
      assert "element" in variants
      assert "exists" in variants
      assert "is_nil" in variants
      assert "zero" in variants

      # ...and the mutate/2 swap families (aggregate / ordering / join / combination).
      assert "sum" in variants
      assert "asc" in variants
      assert "nulls_first" in variants
      assert "left" in variants
      assert "intersect" in variants
      assert "except_all" in variants
    end
  end

  describe "every mutant's Site carries its family and finer label" do
    @src """
    defmodule M do
      import Ecto.Query
      def q, do: from(u in User, where: u.age > 18, select: u.id)
    end
    """

    test "a host-delivered fragment mutant is tagged [family, finer]" do
      sites = sites_for(@src)

      # `u.age > 18` → `u.age >= 18`: the comparison swap *of* `>`, woven through the selector host —
      # so it carries both its family and the operator it mutated.
      assert site(sites, "u.age >= 18").variant == ["comparison", ">"]

      # `18` → `19`: an integer-literal bump (`succ`) of the *same* hosted condition.
      assert site(sites, "u.age > 19").variant == ["integer_literal", "succ"]
    end

    test "a hosted bound bump is tagged family-only (no finer kind)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, limit: 10, select: u.id)
      end
      """

      # The pin-only weave still runs through `Config.tagged/1` + `finalize/2`, so the Site
      # carries its `:bound` family label like every other host-delivered mutant.
      bump = Enum.find(sites_for(src), &(&1.mutator == :ecto and &1.mutated_code == "11"))

      assert bump.variant == ["bound"]
    end

    test "a mutate/2-delivered structural mutant carries only its family (no finer kind)" do
      # Dropping the `where:` rewrites the whole `from`; delivered in place via `mutate/2`, not the
      # host. A clause drop has no operator/kind to name, so it's family-only.
      drop =
        Enum.find(
          sites_for(@src),
          &(&1.mutator == :ecto and &1.mutated_code =~ "from(" and
              not (&1.mutated_code =~ "u.age"))
        )

      assert drop.variant == ["filter_drop"]
    end

    test "the labels ride alongside the equivalence note, independently" do
      # `:comparison` is equivalence-sensitive, so its Site carries *both* the variant labels (for
      # `# mutare:ignore`) and the report note (for the survivor header) — the two are orthogonal.
      comparison = site(sites_for(@src), "u.age >= 18")

      assert comparison.variant == ["comparison", ">"]

      assert comparison.note ==
               "kill may require a row whose value sits exactly on the bound — strict and non-strict comparisons (< vs <=, > vs >=) select the same rows except one equal to the bound"
    end
  end

  describe "# mutare:ignore[ecto:<operator>] suppresses just that operator at a site" do
    test "[ecto:<] kills only the < swap, leaving > (and every other sibling) live" do
      # The headline: target a single operator. The `<` boundary swap is suppressed; the `>` swap,
      # the connective, and the literal bumps on the same line all keep running.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, where: u.age < 40 and u.age > 18) # mutare:ignore[ecto:<]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "u.age <= 40").ignored, "the < swap is suppressed"
      refute site(sites, "u.age >= 18").ignored, "the > swap keeps running"
      refute site(sites, "u.age < 41").ignored, "the literal bump keeps running"
      refute site(sites, "40 or u.age").ignored, "the connective swap keeps running"
    end

    test "[ecto:comparison] (the family) still suppresses both < and > at once" do
      # The coarse label remains available — a family qualifier matches any operator of that family.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, where: u.age < 40 and u.age > 18) # mutare:ignore[ecto:comparison]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "u.age <= 40").ignored, "the < swap is suppressed"
      assert site(sites, "u.age >= 18").ignored, "the > swap is suppressed too"
      refute site(sites, "u.age < 41").ignored, "a non-comparison sibling keeps running"
    end
  end

  describe "# mutare:ignore[ecto:<family>] suppresses a whole family at a site" do
    test "host path — [ecto:integer_literal] kills the bumps, leaving the comparison swap live" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, where: u.age > 18, select: u.id) # mutare:ignore[ecto:integer_literal]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "u.age > 19").ignored, "the literal bump is suppressed"
      refute site(sites, "u.age >= 18").ignored, "the comparison swap keeps running"
    end

    test "mutate/2 path — [ecto:ordering_nulls] kills the NULLs flip, not the direction flip" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, order_by: [asc_nulls_first: u.score], select: u.id) # mutare:ignore[ecto:ordering_nulls]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "asc_nulls_last").ignored, "the NULLs-placement flip is suppressed"
      refute site(sites, "desc_nulls_first").ignored, "the sibling direction flip keeps running"
    end

    test "a bare [ecto] directive still suppresses every mutant at the site (unqualified)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, where: u.age > 18, select: u.id) # mutare:ignore[ecto]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "u.age >= 18").ignored, "the comparison swap is suppressed"
      assert site(sites, "u.age > 19").ignored, "the literal sibling is suppressed too"
    end
  end

  describe "the bound bump's site anchors at the literal — directives moved with it" do
    # The bump used to be a whole-`from` rewrite recorded at the `from`'s start line; hosted
    # pin-only, its Site now carries the literal's own range. Directive matching is exact-line
    # (`Mutare.Ignore.directive_for/4` on `site.line`), so in a multi-line query the directive
    # must sit on the *literal's* line — and one on the `from` opener no longer catches it.
    test "[ecto:bound] on the literal's line suppresses the bumps, not the whole-from drop" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User,
            limit: 10, # mutare:ignore[ecto:bound]
            select: u.id
          )
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "11").ignored, "the +1 bump is suppressed"
      assert site(sites, "9").ignored, "the −1 bump is suppressed"

      drop =
        Enum.find(
          sites,
          &(&1.mutator == :ecto and &1.mutated_code =~ "from(" and
              not (&1.mutated_code =~ "limit"))
        )

      refute drop.ignored, "the drop's site still anchors at the from opener, a different line"
    end

    test "[ecto:bound] on the from's opening line catches the drop but no longer the bump" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, # mutare:ignore[ecto:bound]
            limit: 10,
            select: u.id
          )
        end
      end
      """

      sites = sites_for(src)

      drop =
        Enum.find(
          sites,
          &(&1.mutator == :ecto and &1.mutated_code =~ "from(" and
              not (&1.mutated_code =~ "limit"))
        )

      assert drop.ignored, "the whole-from drop is still recorded at the from's start line"
      refute site(sites, "11").ignored, "the bump's site moved to the literal's line"
      refute site(sites, "9").ignored
    end
  end

  describe "# mutare:ignore[ecto:<operator>] on a mutate/2 swap family" do
    test "[ecto:sum] kills the sum swap, leaving avg live (aggregate)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, select: {sum(u.age), avg(u.age)}) # mutare:ignore[ecto:sum]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "avg(u.age), avg").ignored, "the sum → avg swap is suppressed"
      refute site(sites, "sum(u.age), sum").ignored, "the avg → sum swap keeps running"
    end

    test "[ecto:asc] kills the asc direction flip, leaving desc live (ordering)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(u in User, order_by: [asc: u.name, desc: u.age], select: u.id) # mutare:ignore[ecto:asc]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "desc: u.name").ignored, "the asc → desc flip is suppressed"
      refute site(sites, "asc: u.age").ignored, "the desc → asc flip keeps running"
    end

    test "[ecto:left] kills the left-join swap, leaving the full-join swap live (join_type)" do
      # One line so the whole-`from` site (recorded at the `from`'s start line) sits on the same line
      # as the trailing directive. `inner_join`/`join` are never a flip source (widening is not
      # offered), so the second join here is `full_join` — narrows to `left_join`, portably.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(p in Post, left_join: u in assoc(p, :user), full_join: a in assoc(p, :author), select: p.id) # mutare:ignore[ecto:left]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "inner_join: u").ignored, "the left → inner swap is suppressed"
      refute site(sites, "left_join: a").ignored, "the full → left swap keeps running"
    end
  end
end
