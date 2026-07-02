defmodule Mutare.Ecto.SubcontractTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The **island sub-contract** end to end: a hosted `where`/`having` condition may contain
  # interpolation islands (`^expr`) — ordinary Elixir evaluated at runtime, exactly core's
  # business. The host hands each interior to core's generation
  # (`Mutare.Analyze.expression_mutations/3` over `context.mutators`, the run's enabled non-host
  # specs) and relays the rebuilds through its own weave with `producer:` attribution
  # (`Mutare.Ecto.Host.Catalog`), so:
  #
  #   * the recorded Site belongs to the producing *core* family (`:arithmetic`, `:literal`, …) —
  #     its name, its conventions, its `# mutare:ignore` vocabulary — never to `:ecto`;
  #   * delivery stays 100% host-owned — the island mutants are just more branches of the same
  #     woven `^`/`dynamic` selector (SemanticTest proves one is live at runtime);
  #   * the plugin's own SQL catalog never reasons about the interior (an SQL-rationale
  #     `^(min * 2)` → `^(min / 2)` would mutate the *parameter's* Elixir value/type) — with no
  #     core families in the run, the interior simply produces nothing.

  # The plugin plus core's builtins — the sub-contract needs core families to contract *to*.
  @with_core [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  # The core-attributed `{mutator, original, mutated}` triples recorded against a hosted
  # condition carrying a pin — the sub-contracted island mutants (always a *core* family's,
  # never `:ecto`'s; the whole-`from`/def-body sites core also records are filtered out by
  # their originals).
  defp island_diffs(src, opts) do
    for {mutator, original, mutated} <- diffs(src, opts),
        mutator != :ecto,
        String.contains?(original, "^("),
        not String.starts_with?(original, "from("),
        not String.starts_with?(original, "def "),
        do: {mutator, original, mutated}
  end

  describe "attribution — island mutants record under the producing core family" do
    test "a from-keyword where's pin interior mutates under core's families, not :ecto" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: u.age > ^(min * 2), select: u.id)
      end
      """

      islands = island_diffs(src, @with_core)

      # Core's arithmetic and literal families reason about the interior — with core's Elixir
      # conventions — while the recorded diff is the logical hosted condition.
      assert {:arithmetic, "u.age > ^(min * 2)", "u.age > ^(min / 2)"} in islands
      assert {:literal, "u.age > ^(min * 2)", "u.age > ^(min * 3)"} in islands

      # No island mutant is ever the host's: the plugin's `:ecto` sites on that condition are
      # exactly its own SQL catalog (the comparison swap), nothing inside the pin.
      assert [{"u.age > ^(min * 2)", "u.age >= ^(min * 2)"}] =
               src
               |> ecto_diffs(@with_core)
               |> Enum.filter(fn {original, _} -> original == "u.age > ^(min * 2)" end)

      assert_compiles(src, @with_core)
    end

    test "a standalone/pipe where's pin interior sub-contracts identically" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(q, min), do: q |> where([u], u.age > ^(min + 1))
      end
      """

      assert {:arithmetic, "u.age > ^(min + 1)", "u.age > ^(min - 1)"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end

    test "a hosted join on: condition's pin interior sub-contracts too" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(q, min), do: join(q, :inner, [u], p in Post, on: p.views > ^(min + 1))
      end
      """

      assert {:arithmetic, "p.views > ^(min + 1)", "p.views > ^(min - 1)"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end
  end

  describe "delivery — island mutants ride the host's weave" do
    test "the interior rebuild is woven behind the same dynamic as the host's own mutants" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: u.age > ^(min * 2), select: u.id)
      end
      """

      mm = metamutant(src, @with_core)
      # One woven selector carries both the host's comparison swap and the relayed island
      # rebuild — the island mutant is a branch of the host's dynamic, not an in-place selector
      # inside the query (which would poison the build).
      assert mm =~ "dynamic([u]"
      assert mm =~ "u.age > ^(min / 2)"
      assert_compiles(src, @with_core)
    end
  end

  describe "configuration — the interior follows the run's actual mutators" do
    test "with no core families in the run, a pin interior produces nothing" do
      # Plugin-only (the TestSupport default): there is nobody to sub-contract to, and the SQL
      # catalog never reasons about the interior itself — so the pin contributes no mutants at
      # all (rather than the old SQL-rationale `^(min / 2)` crash-mutant).
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: u.age > ^(min * 2), select: u.id)
      end
      """

      # Exactly the plugin's own catalog — the comparison swap and the whole-`from` clause drop.
      # No `^(min / 2)`, no `^(min * 3)`: the interior is nobody's here.
      assert MapSet.new(ecto_diffs(src)) ==
               MapSet.new([
                 {"u.age > ^(min * 2)", "u.age >= ^(min * 2)"},
                 {"from(u in User, where: u.age > ^(min * 2), select: u.id)",
                  "from(u in User, select: u.id)"}
               ])

      assert_compiles(src)
    end

    test "a narrowed core selection narrows the island mutants with it" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: u.age > ^(min * 2), select: u.id)
      end
      """

      islands = island_diffs(src, mutators: [:arithmetic, {Mutare.Ecto, repo: MyApp.Repo}])

      assert [{:arithmetic, _, "u.age > ^(min / 2)"}] = islands
    end
  end

  describe "reach — islands follow the catalog's own descent rules" do
    test "an island inside a written in-list is reached" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(base), do: from(u in User, where: u.age in [18, ^(base + 1)], select: u.id)
      end
      """

      assert {:arithmetic, "u.age in [18, ^(base + 1)]", "u.age in [18, ^(base - 1)]"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end

    test "an island under is_nil is not sub-contracted (value mutants preserve NULL-ness)" do
      # The catalog never descends an `is_nil` argument — a parameter's value mutants keep a
      # non-NULL value non-NULL, so inside the one predicate that observes only NULL-ness they
      # are provably equivalent. The island walk honors the same boundary.
      src = """
      defmodule M do
        import Ecto.Query
        def q(d), do: from(u in User, where: is_nil(coalesce(u.age, ^(d + 1))), select: u.id)
      end
      """

      assert island_diffs(src, @with_core) == []
      assert_compiles(src, @with_core)
    end

    test "a top-level pin condition stays raw — no host, no sub-contract" do
      # `where: ^cond` is routed `:skip` (already-evaluated Elixir, "mutated where it is
      # built"); the sub-contract only exists inside a *hosted* condition.
      src = """
      defmodule M do
        import Ecto.Query
        def q(c), do: from(u in User, where: ^(c and true), select: u.id)
      end
      """

      assert island_diffs(src, []) == []
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end
  end
end
