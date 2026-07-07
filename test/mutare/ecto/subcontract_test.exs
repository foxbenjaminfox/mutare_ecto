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
  # their originals, and `:return_value` — which mutates def bodies whole, never expressions,
  # so it can't produce an island mutant — by name, since a single-expression body's site is
  # the pin-carrying call itself).
  defp island_diffs(src, opts) do
    for {mutator, original, mutated} <- diffs(src, opts),
        mutator not in [:ecto, :return_value],
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
      # exactly its own SQL catalog (the comparison swap and the clause-level filter drop),
      # nothing inside the pin.
      assert MapSet.new([
               {"u.age > ^(min * 2)", "u.age >= ^(min * 2)"},
               {"u.age > ^(min * 2)", ""}
             ]) ==
               src
               |> ecto_diffs(@with_core)
               |> Enum.filter(fn {original, _} -> original == "u.age > ^(min * 2)" end)
               |> MapSet.new()

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

    test "a from-keyword join's on: pin interior sub-contracts (the from_targets door)" do
      # The `on:` of a `from`'s `join:` clause reaches the host through `Host.from_targets`, not
      # the standalone `join/5` door above — both must hand the island to core.
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, join: p in Post, on: p.views > ^(min + 1), select: u.id)
      end
      """

      assert {:arithmetic, "p.views > ^(min + 1)", "p.views > ^(min - 1)"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end

    test "a from-keyword having's pin interior sub-contracts alongside the aggregate swap" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(n), do: from(p in Post, group_by: p.user_id, having: sum(p.views) > ^(n * 2), select: p.user_id)
      end
      """

      assert {:arithmetic, "sum(p.views) > ^(n * 2)", "sum(p.views) > ^(n / 2)"} in island_diffs(
               src,
               @with_core
             )

      # The host's own catalog still owns the SQL side of the same condition — the aggregate
      # swap and the comparison swap ride the same weave as the relayed island mutant.
      ecto = ecto_diffs(src, @with_core)
      assert {"sum(p.views) > ^(n * 2)", "avg(p.views) > ^(n * 2)"} in ecto
      assert {"sum(p.views) > ^(n * 2)", "sum(p.views) >= ^(n * 2)"} in ecto

      assert_compiles(src, @with_core)
    end

    test "a piped having's pin interior sub-contracts (the condition_target door)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(q, n), do: q |> having([p], sum(p.views) > ^(n + 1))
      end
      """

      assert {:arithmetic, "sum(p.views) > ^(n + 1)", "sum(p.views) > ^(n - 1)"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end

    test "a binding-less named-binding where's pin sub-contracts (the empty-binding dynamic)" do
      # No written binding list at all — the condition references a named binding, so the host
      # weaves a `dynamic([], …)`; the island rides that weave like any other.
      src = """
      defmodule M do
        import Ecto.Query
        def q(min) do
          from(u in User, as: :user, select: u.id)
          |> where(as(:user).age > ^(min + 1))
        end
      end
      """

      assert {:arithmetic, "as(:user).age > ^(min + 1)", "as(:user).age > ^(min - 1)"} in island_diffs(
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
                 {"u.age > ^(min * 2)", ""}
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

    test "the plugin's families: filter never touches the sub-contract" do
      # The island mutants are a core family's, so the plugin's SQL-family selection doesn't
      # apply to them: with `families:` narrowed to something this condition can't produce, the
      # host's own catalog yields *nothing* — yet it still weaves, purely to carry the relayed
      # island mutants.
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: u.age > ^(min * 2), select: u.id)
      end
      """

      opts = [
        mutators: [:arithmetic, {Mutare.Ecto, repo: MyApp.Repo, families: [:null_predicate]}]
      ]

      assert [{:arithmetic, _, "u.age > ^(min / 2)"}] = island_diffs(src, opts)

      # No `:ecto` mutant on the condition (the comparison swap is filtered out)…
      refute Enum.any?(ecto_diffs(src, opts), fn {original, _} ->
               original == "u.age > ^(min * 2)"
             end)

      # …but the weave is still there, carrying the island alone.
      assert metamutant(src, opts) =~ "dynamic([u]"
      assert_compiles(src, opts)
    end

    test "an :as-renamed core instance attributes its island mutants under the rename" do
      # Core generates under the user's actual specs — an `:as` rename is part of the identity
      # the relayed `producer:` carries, so the Site (and report grouping) follows it.
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: u.age > ^(min * 2), select: u.id)
      end
      """

      islands =
        island_diffs(src,
          mutators: [{Mutare.Mutators.Arithmetic, as: :math}, {Mutare.Ecto, repo: MyApp.Repo}]
        )

      assert [{:math, "u.age > ^(min * 2)", "u.age > ^(min / 2)"}] = islands
    end
  end

  describe "# mutare:ignore — the island's vocabulary is the producer's, never :ecto's" do
    # The Sites recorded for `src` under the plugin + core's builtins, with ignore directives
    # resolved (the `diffs` helpers drop the `ignored` flag, so go through the transform).
    defp sites_for(src) do
      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          file: "subcontract_ignore_fixture.ex",
          mutators: Mutare.Ecto.TestSupport.mutators(@with_core),
          expand_uses: true
        )

      sites
    end

    defp site(sites, mutator, substring) do
      found = Enum.find(sites, &(&1.mutator == mutator and &1.mutated_code =~ substring))
      assert found, "no #{inspect(mutator)} site matching #{inspect(substring)}"
      found
    end

    test "[arithmetic] suppresses the island mutant while the host's own swap keeps running" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(min) do
          from(u in User, where: u.age > ^(min * 2), select: u.id) # mutare:ignore[arithmetic]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, :arithmetic, "u.age > ^(min / 2)").ignored,
             "the island's arithmetic mutant answers to core's family name"

      refute site(sites, :ecto, "u.age >= ^(min * 2)").ignored,
             "the host's own comparison swap is not [arithmetic]'s to suppress"

      refute site(sites, :literal, "u.age > ^(min * 3)").ignored,
             "a sibling island producer keeps running"
    end

    test "[ecto] suppresses the host's own catalog but no producer-attributed island mutant" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(min) do
          from(u in User, where: u.age > ^(min * 2), select: u.id) # mutare:ignore[ecto]
        end
      end
      """

      sites = sites_for(src)

      assert site(sites, :ecto, "u.age >= ^(min * 2)").ignored

      refute site(sites, :arithmetic, "u.age > ^(min / 2)").ignored,
             "the island mutant belongs to core's family, not [ecto]'s vocabulary"
    end

    test "the vocabulary holds on the whole-call relays of a free-standing dynamic too" do
      # The dynamic's island mutants ride the in-place selector, not a weave — but the ignore
      # resolution is the same: `[arithmetic]` names the relay, `[ecto]` names only the
      # plugin's own catalog on the same call.
      arithmetic_src = """
      defmodule M do
        import Ecto.Query
        def d(min) do
          dynamic([p], p.views > ^(min * 2)) # mutare:ignore[arithmetic]
        end
      end
      """

      sites = sites_for(arithmetic_src)

      assert site(sites, :arithmetic, "p.views > ^(min / 2)").ignored
      refute site(sites, :ecto, "p.views >= ^(min * 2)").ignored
      refute site(sites, :literal, "p.views > ^(min * 3)").ignored

      ecto_src = """
      defmodule M do
        import Ecto.Query
        def d(min) do
          dynamic([p], p.views > ^(min * 2)) # mutare:ignore[ecto]
        end
      end
      """

      sites = sites_for(ecto_src)

      assert site(sites, :ecto, "p.views >= ^(min * 2)").ignored
      refute site(sites, :arithmetic, "p.views > ^(min / 2)").ignored
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

    test "an island under a `not in` polarity unit is reached, rebuilt inside the not" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(base), do: from(u in User, where: u.age not in [18, ^(base + 1)], select: u.id)
      end
      """

      assert {:arithmetic, "u.age not in [18, ^(base + 1)]", "u.age not in [18, ^(base - 1)]"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end

    test "an island at a data position of a fragment(...) call is reached" do
      # The structural-position guard protects *literals* (the SQL template) — a pin at a data
      # position is ordinary Elixir like any other island.
      src = """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(u in User, where: fragment("? > ?", u.age, ^(min * 2)), select: u.id)
      end
      """

      assert {:arithmetic, ~s|fragment("? > ?", u.age, ^(min * 2))|,
              ~s|fragment("? > ?", u.age, ^(min / 2))|} in island_diffs(src, @with_core)

      assert_compiles(src, @with_core)
    end

    test "an island as a coalesce default is reached — the contrast with is_nil" do
      # `coalesce`'s arguments are descended (the catalog's own drop keeps walking), so its
      # NULL-fallback pin is sub-contracted — unlike the same pin under `is_nil` above.
      src = """
      defmodule M do
        import Ecto.Query
        def q(d), do: from(u in User, where: coalesce(u.score, ^(d + 1)) > 10, select: u.id)
      end
      """

      assert {:arithmetic, "coalesce(u.score, ^(d + 1)) > 10", "coalesce(u.score, ^(d - 1)) > 10"} in island_diffs(
               src,
               @with_core
             )

      assert_compiles(src, @with_core)
    end

    test "every pin in a compound condition is its own single-point island" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(lo, hi), do: from(u in User, where: u.age > ^(lo + 1) and u.age < ^(hi - 1), select: u.id)
      end
      """

      islands = island_diffs(src, @with_core)
      original = "u.age > ^(lo + 1) and u.age < ^(hi - 1)"

      # Each island mutates alone — the sibling pin rides along verbatim in both rebuilds.
      assert {:arithmetic, original, "u.age > ^(lo - 1) and u.age < ^(hi - 1)"} in islands
      assert {:arithmetic, original, "u.age > ^(lo + 1) and u.age < ^(hi + 1)"} in islands

      # And no relayed rebuild ever touches both pins at once.
      refute Enum.any?(islands, fn {_m, _o, mutated} ->
               mutated =~ "lo - 1" and mutated =~ "hi + 1"
             end)

      assert_compiles(src, @with_core)
    end

    test "an author macro's :expression argument sub-contracts; its :skip argument never does" do
      # The island walk reads the same per-argument routing as the catalogs — the routing shipped
      # by core's `Mutare.Test.Fixtures.RoutingExtension`: `tagged/2` routes its condition
      # `:expression` (standard syntax — descend), `opaque/1` is fully `:skip` (the macro's own
      # grammar — opaque). The same sources *without* the extension both sub-contract, isolating
      # the routing as what suppresses the second.
      helper = @with_core ++ [extensions: [Mutare.Test.Fixtures.RoutingExtension]]

      tagged = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q(n), do: from(u in User, where: tagged(u.age > ^(n + 1), :urgent), select: u.id)
      end
      """

      assert {:arithmetic, "tagged(u.age > ^(n + 1), :urgent)",
              "tagged(u.age > ^(n - 1), :urgent)"} in island_diffs(tagged, helper)

      opaque = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q(n), do: from(u in User, where: opaque(u.age > ^(n + 1)), select: u.id)
      end
      """

      assert island_diffs(opaque, helper) == []

      # Unregistered, the same call has `nil` routing — plainly standard syntax, descended.
      assert {:arithmetic, "opaque(u.age > ^(n + 1))", "opaque(u.age > ^(n - 1))"} in island_diffs(
               opaque,
               @with_core
             )

      assert_compiles(tagged, helper)
      assert_compiles(opaque, helper)
    end

    test "a non-hostable join on: (assoc join) is never hosted, so its pin never sub-contracts" do
      # An `assoc(...)` join's implicit condition folds the `on:` under an `and`, where a
      # `^dynamic` operand is illegal — `Host.JoinOn` gates it out, and with no host there is
      # no sub-contract (nor any in-fragment `:ecto` mutant on that condition).
      src = """
      defmodule M do
        import Ecto.Query
        def q(q, min), do: join(q, :inner, [u], p in assoc(u, :posts), on: p.views > ^(min + 1))
      end
      """

      assert island_diffs(src, @with_core) == []

      # No in-fragment `:ecto` mutant on the condition either — the whole-call families (the
      # join's stage drop, whose original is the full `join(...)` call) still apply.
      refute Enum.any?(ecto_diffs(src, @with_core), fn {original, _} ->
               original == "p.views > ^(min + 1)"
             end)

      assert_compiles(src, @with_core)
    end

    test "a pin in a select value is not sub-contracted — the sub-contract lives in the host" do
      # `select:` values are walked by the scalar catalogs and delivered via `mutate/2` (no
      # host, no weave) — so their pin interiors have no sub-contract seam. The interior stays
      # unmutated; core mutates a `^value`'s expression where it is *built*, upstream, as always.
      src = """
      defmodule M do
        import Ecto.Query
        def q(n), do: from(u in User, select: u.age + ^(n + 1))
      end
      """

      assert island_diffs(src, @with_core) == []
      refute Enum.any?(diffs(src, @with_core), fn {_m, _o, mutated} -> mutated =~ "n - 1" end)
      assert_compiles(src, @with_core)
    end
  end

  describe "the whole-call seam — a free-standing dynamic's islands" do
    # The second consumer of the sub-contract: `dynamic` registers `:skip`, so core keeps the
    # DSL argument raw — but core threads the run's specs into the whole-call offer of a
    # registered macro (`context.mutators`), so `Mutare.Ecto.Dynamic` sub-contracts each island
    # through the same seam as the host (`Host.Catalog.subcontracted/3`). Only delivery differs:
    # each relayed mutant is the whole `dynamic` call rebuilt, passed through
    # `Mutare.Ecto.mutate/2` untouched (no `families:` filter — the mutant is a core family's)
    # and delivered by the ordinary in-place selector (no weave — the call sits in expression
    # position).

    test "an inline island sub-contracts as a whole-call rewrite" do
      src = """
      defmodule M do
        import Ecto.Query
        def d(min), do: dynamic([p], p.views > ^(min * 2))
      end
      """

      islands = island_diffs(src, @with_core)
      original = "dynamic([p], p.views > ^(min * 2))"

      assert {:arithmetic, original, "dynamic([p], p.views > ^(min / 2))"} in islands
      assert {:literal, original, "dynamic([p], p.views > ^(min * 3))"} in islands

      # The island mutant is never `:ecto`'s: the plugin's own sites on the call are exactly its
      # SQL catalog (the comparison swap), nothing inside the pin.
      assert [{original, "dynamic([p], p.views >= ^(min * 2))"}] ==
               ecto_diffs(src, @with_core)

      assert_compiles(src, @with_core)
    end

    test "the binding-less dynamic/1 form sub-contracts too" do
      # The condition sits at a different argument slot (the trailing argument, no written
      # binding list) — `Bindings.hosted_condition/1` resolves the index the whole-call wrap
      # rebuilds around, so both shapes must relay.
      src = """
      defmodule M do
        import Ecto.Query
        def d(min), do: dynamic(as(:post).views > ^(min + 1))
      end
      """

      assert {:arithmetic, "dynamic(as(:post).views > ^(min + 1))",
              "dynamic(as(:post).views > ^(min - 1))"} in island_diffs(src, @with_core)

      assert_compiles(src, @with_core)
    end

    test "every pin is its own single-point whole-call rewrite" do
      # Each island's rebuild wraps back into the whole call independently — the sibling pin
      # rides along verbatim in every relayed mutant.
      src = """
      defmodule M do
        import Ecto.Query
        def d(lo, hi), do: dynamic([p], p.views > ^(lo + 1) and p.views < ^(hi - 1))
      end
      """

      islands = island_diffs(src, @with_core)
      original = "dynamic([p], p.views > ^(lo + 1) and p.views < ^(hi - 1))"

      assert {:arithmetic, original, "dynamic([p], p.views > ^(lo - 1) and p.views < ^(hi - 1))"} in islands

      assert {:arithmetic, original, "dynamic([p], p.views > ^(lo + 1) and p.views < ^(hi + 1))"} in islands

      refute Enum.any?(islands, fn {_m, _o, mutated} ->
               mutated =~ "lo - 1" and mutated =~ "hi + 1"
             end)

      assert_compiles(src, @with_core)
    end

    test "the islands honor the catalog's descent rules inside a dynamic too" do
      # The same `Fragment.islands/1` walk serves both consumers — an `is_nil` argument is a
      # hard boundary in a dynamic exactly as in a hosted where.
      src = """
      defmodule M do
        import Ecto.Query
        def d(v), do: dynamic([p], is_nil(coalesce(p.views, ^(v + 1))))
      end
      """

      assert island_diffs(src, @with_core) == []
      assert_compiles(src, @with_core)
    end

    test "a :skip author macro's pin inside a dynamic never sub-contracts" do
      # The author-macro rule rides the shared walk: `opaque/1` (core's shipped
      # `RoutingExtension` fixture, threaded via `extensions:`) is registered fully `:skip` —
      # its argument is the macro's own grammar, opaque to the island walk. Without the
      # extension the same pin is reached (the contrast that isolates the routing).
      helper = @with_core ++ [extensions: [Mutare.Test.Fixtures.RoutingExtension]]

      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def d(n), do: dynamic([u], opaque(u.age > ^(n + 1)))
      end
      """

      assert island_diffs(src, helper) == []

      assert {:arithmetic, "dynamic([u], opaque(u.age > ^(n + 1)))",
              "dynamic([u], opaque(u.age > ^(n - 1)))"} in island_diffs(src, @with_core)

      assert_compiles(src, helper)
    end

    test "the plugin's families: filter never touches the whole-call relays" do
      # The pass-through in `Mutare.Ecto.mutate/2`: with `families:` narrowed to something this
      # condition can't produce, the plugin's own catalog contributes nothing — yet the call
      # still mutates, purely to carry the relayed island mutants (mutate/2 must not collapse
      # to :skip while relays remain).
      src = """
      defmodule M do
        import Ecto.Query
        def d(min), do: dynamic([p], p.views > ^(min * 2))
      end
      """

      opts = [
        mutators: [:arithmetic, {Mutare.Ecto, repo: MyApp.Repo, families: [:null_predicate]}]
      ]

      assert [{:arithmetic, _, "dynamic([p], p.views > ^(min / 2))"}] = island_diffs(src, opts)
      assert ecto_diffs(src, opts) == []
      assert_compiles(src, opts)
    end

    test "an :as-renamed core instance attributes the whole-call relays under the rename" do
      src = """
      defmodule M do
        import Ecto.Query
        def d(min), do: dynamic([p], p.views > ^(min * 2))
      end
      """

      islands =
        island_diffs(src,
          mutators: [{Mutare.Mutators.Arithmetic, as: :math}, {Mutare.Ecto, repo: MyApp.Repo}]
        )

      assert [{:math, _, "dynamic([p], p.views > ^(min / 2))"}] = islands
    end

    test "parity — the same interior yields the same core mutants in a where and a dynamic" do
      # The commit-level promise of the whole-call seam: an identical pin interior no longer
      # gets core's island mutants in a `where` and nothing in a `dynamic`. Only the delivery
      # shape differs (bare condition for the weave vs. the whole rebuilt call), so compare the
      # mutated *conditions*.
      where_src = """
      defmodule M do
        import Ecto.Query
        def q(q, min), do: q |> where([p], p.views > ^(min * 2))
      end
      """

      dynamic_src = """
      defmodule M do
        import Ecto.Query
        def d(min), do: dynamic([p], p.views > ^(min * 2))
      end
      """

      condition = fn
        "dynamic([p], " <> rest -> String.replace_suffix(rest, ")", "")
        bare -> bare
      end

      logical = fn src ->
        MapSet.new(island_diffs(src, @with_core), fn {mutator, _original, mutated} ->
          {mutator, condition.(mutated)}
        end)
      end

      assert MapSet.size(logical.(where_src)) > 0
      assert logical.(where_src) == logical.(dynamic_src)
    end

    test "a top-level-pin dynamic body stays raw — no catalog, no sub-contract" do
      # `dynamic([p], ^other)`'s body is already-evaluated Elixir bound upstream ("mutated where
      # it is built") — exactly as a hosted `where: ^cond` stays raw, the whole-call seam leaves
      # a top-level pin alone.
      src = """
      defmodule M do
        import Ecto.Query
        def d(c), do: dynamic([p], ^(c and true))
      end
      """

      assert island_diffs(src, @with_core) == []
      assert ecto_diffs(src, @with_core) == []
      assert_compiles(src, @with_core)
    end
  end

  describe "totality — subcontracted/2,3 tolerates a context with no :mutators key" do
    # `Map.get(context, :mutators, [])` defaults to `[]` when the key is absent. Every real caller
    # (`host/2`, `Mutare.Ecto.Dynamic`) reaches this through core's `analyze_known_macro/5`, which
    # always injects `:mutators` first — so a bare context never occurs on that path. Still, the
    # function's own contract (`@spec subcontracted(Macro.t(), Mutare.Mutator.context(), ...)`)
    # doesn't require the key, so drive it directly with a context that omits it (mirroring how
    # `Mutare.Ecto.Clause.mutations/2` is tested with a bare `%{}` elsewhere): it degrades to no
    # sub-contracted mutants rather than raising a `KeyError`/`FunctionClauseError` inside the
    # `for` comprehension's `Mutare.Analyze.expression_mutations/3` call.
    test "a context with no :mutators key yields no sub-contracted mutants, never crashes" do
      condition = Sourceror.parse_string!("u.age > ^(min * 2)")
      assert Mutare.Ecto.Host.Catalog.subcontracted(condition, %{}) == []
    end
  end
end
