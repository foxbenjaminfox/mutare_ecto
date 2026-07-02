defmodule Mutare.Ecto.VariantTest do
  use ExUnit.Case, async: true

  # `# mutare:ignore[ecto:<label>]` variant suppression. Every recorded mutant is tagged (via
  # `Mutare.Ecto.Config.enrich/3`) with its SQL **family** and, for a swap/value family, the finer
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
      assert "is_nil" in variants
      assert "zero" in variants

      # ...and the mutate/2 swap families (aggregate / ordering / join).
      assert "sum" in variants
      assert "asc" in variants
      assert "nulls_first" in variants
      assert "left" in variants
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

    test "[ecto:left] kills the left-join swap, leaving the inner-join swap live (join_type)" do
      # One line so the whole-`from` site (recorded at the `from`'s start line) sits on the same line
      # as the trailing directive.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(p in Post, left_join: u in assoc(p, :user), inner_join: a in assoc(p, :author), select: p.id) # mutare:ignore[ecto:left]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, "inner_join: u").ignored, "the left → inner swap is suppressed"
      refute site(sites, "left_join: a").ignored, "the inner → left swap keeps running"
    end
  end
end
