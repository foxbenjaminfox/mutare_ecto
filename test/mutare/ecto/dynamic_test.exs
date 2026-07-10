defmodule Mutare.Ecto.DynamicTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # In-fragment SQL mutations for a *free-standing* `dynamic/1,2` (`Mutare.Ecto.Dynamic`): the same
  # `Fragment`/`Aggregate` catalogs a hosted `where`/`having` runs, but delivered as **whole-call
  # rewrites** through Mutare's ordinary in-place selector — a free-standing `dynamic` sits in plain
  # expression position (its value is a runtime `DynamicExpr`), so no `^`/`dynamic` weaving is
  # needed. This is the build site the `where(q, ^d)` splice deliberately leaves raw ("mutated
  # where it is built" — `Mutare.Ecto.Host.Bindings`).

  # The full-family plugin instance plus core's shipped routing-only fixture
  # (`Mutare.Test.Fixtures.RoutingExtension`, threaded via `extensions:`), for the nested-`:skip`
  # opacity test — foreign macro routing shipped by an independent module, no hand-rolled provider.
  @all_families [{Mutare.Ecto, repo: MyApp.Repo, families: :all}]
  @routing [Mutare.Test.Fixtures.RoutingExtension]

  # The mutated whole-node renderings recorded under the `:ecto` family.
  defp mutated(src, opts \\ []), do: src |> ecto_diffs(opts) |> Enum.map(fn {_o, m} -> m end)

  describe "the binding form (dynamic/2)" do
    test "a comparison swaps, recorded as the whole rebuilt call" do
      src = """
      defmodule M do
        import Ecto.Query
        def d(v), do: dynamic([p], p.views > ^v)
      end
      """

      # Exactly the one single-point swap — the diff is the whole call (in-place delivery), the
      # written binding list re-emitted untouched, and the pinned interpolation left to core.
      assert ecto_diffs(src) == [{"dynamic([p], p.views > ^v)", "dynamic([p], p.views >= ^v)"}]
      assert_compiles(src)
    end

    test "a nested pin's interior is an island the catalog never enters" do
      # `^(min * 2)` is ordinary Elixir — never the SQL catalog's to reason about. The interior
      # is **sub-contracted** to core's generation exactly as in a hosted `where`/`having`
      # (`subcontract_test.exs` covers the relay); in this plugin-only run there is nobody to
      # sub-contract to, so the interior yields nothing — and never the SQL-rationale
      # `^(min / 2)` crash-mutant.
      src = """
      defmodule M do
        import Ecto.Query
        def d(min), do: dynamic([p], p.views > ^(min * 2))
      end
      """

      assert ecto_diffs(src) ==
               [{"dynamic([p], p.views > ^(min * 2))", "dynamic([p], p.views >= ^(min * 2))"}]

      assert_compiles(src)
    end

    test "every condition position mutates independently (connective + both operands)" do
      src = """
      defmodule M do
        import Ecto.Query
        def d(x, y), do: dynamic([p], p.a > ^x and p.b == ^y)
      end
      """

      muts = MapSet.new(mutated(src))

      assert MapSet.subset?(
               MapSet.new([
                 "dynamic([p], p.a > ^x or p.b == ^y)",
                 "dynamic([p], p.a >= ^x and p.b == ^y)",
                 "dynamic([p], p.a > ^x and p.b != ^y)"
               ]),
               muts
             )

      assert_compiles(src)
    end

    test "an in-fragment integer literal gets the SQL literal arm (boundary ± zero)" do
      src = """
      defmodule M do
        import Ecto.Query
        def d, do: dynamic([p], p.views > 100)
      end
      """

      muts = MapSet.new(mutated(src))

      assert MapSet.subset?(
               MapSet.new([
                 "dynamic([p], p.views >= 100)",
                 "dynamic([p], p.views > 101)",
                 "dynamic([p], p.views > 99)",
                 "dynamic([p], p.views > 0)"
               ]),
               muts
             )

      assert_compiles(src)
    end

    test "a null predicate flips as a unit" do
      src = """
      defmodule M do
        import Ecto.Query
        def d, do: dynamic([p], is_nil(p.deleted_at))
      end
      """

      assert "dynamic([p], not is_nil(p.deleted_at))" in mutated(src)
      assert_compiles(src)
    end

    test "an aggregate inside a having-destined dynamic swaps along its ladder" do
      src = """
      defmodule M do
        import Ecto.Query
        def d(n), do: dynamic([p], sum(p.views) > ^n)
      end
      """

      diffs = ecto_diffs(src)
      orig = "dynamic([p], sum(p.views) > ^n)"
      # Origin pinned: the aggregate swaps down its ladder and the comparison swaps, each a
      # distinct single-point mutant of the same rebuilt call.
      assert {"sum(p.views)", "avg(p.views)"} in diffs
      assert {orig, "dynamic([p], sum(p.views) >= ^n)"} in diffs
      assert_compiles(src)
    end

    test "the qualified form mutates exactly like the imported one" do
      qualified = """
      defmodule M do
        require Ecto.Query
        def d(v), do: Ecto.Query.dynamic([p], p.views > ^v)
      end
      """

      imported = """
      defmodule M do
        import Ecto.Query
        def d(v), do: dynamic([p], p.views > ^v)
      end
      """

      # "Exactly like" is asserted, not sampled: strip the written `Ecto.Query.` prefix and the
      # two forms' full diff sets must be identical — they resolve to the one macro.
      strip = fn diffs ->
        Enum.map(diffs, fn {o, m} ->
          {String.replace(o, "Ecto.Query.", ""), String.replace(m, "Ecto.Query.", "")}
        end)
      end

      assert strip.(ecto_diffs(qualified)) == ecto_diffs(imported)
      assert_compiles(qualified)
    end

    test "the written binding list reorders in place (BindingReorder, never a body rewrite)" do
      src = """
      defmodule M do
        import Ecto.Query
        def d, do: dynamic([a, b], a.id > b.id)
      end
      """

      # Exactly two single-point mutants, origin pinned: the operator swap and the in-place
      # binding transposition (which swaps only the declaration — the body is byte-for-byte intact).
      assert ecto_diffs(src) == [
               {"dynamic([a, b], a.id > b.id)", "dynamic([a, b], a.id >= b.id)"},
               {"dynamic([a, b], a.id > b.id)", "dynamic([b, a], a.id > b.id)"}
             ]

      assert_compiles(src)
    end
  end

  describe "the binding-less form (dynamic/1)" do
    test "a named-binding condition mutates too" do
      src = """
      defmodule M do
        import Ecto.Query
        def d, do: dynamic(as(:post).views > 100)
      end
      """

      assert {"dynamic(as(:post).views > 100)", "dynamic(as(:post).views >= 100)"} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end
  end

  describe "what stays raw" do
    test "a top-level pin body is left to core upstream (ordinary Elixir, not SQL)" do
      src = """
      defmodule M do
        import Ecto.Query
        def d(other), do: dynamic([p], ^other)
      end
      """

      assert ecto_diffs(src) == []
      assert_compiles(src)
    end

    test "a nested :skip author macro is opaque — its in-fragment literals never mutate" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def d(v), do: dynamic([u], opaque(u.age > 18) and u.role == ^v)
      end
      """

      muts = mutated(src, mutators: @all_families, extensions: @routing)

      # The sibling positions still mutate (the anchor that proves the walk ran)…
      assert Enum.any?(muts, &(&1 =~ "or u.role"))
      assert Enum.any?(muts, &(&1 =~ "u.role != ^v"))
      # …but `opaque/1`'s argument is its DSL (routed fully `:skip`), never descended.
      refute Enum.any?(muts, &(&1 =~ "u.age >= 18" or &1 =~ "17" or &1 =~ "19"))
      assert_compiles(src, extensions: @routing)
    end

    test "the families: filter applies — a comparison-only run drops the literal arms" do
      src = """
      defmodule M do
        import Ecto.Query
        def d, do: dynamic([p], p.views > 100)
      end
      """

      muts = mutated(src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:comparison]}])
      assert muts == ["dynamic([p], p.views >= 100)"]
    end
  end

  describe "the report note" do
    test "an equivalence-sensitive dynamic mutant carries its note through mutate/2" do
      src = """
      defmodule M do
        import Ecto.Query
        def d, do: dynamic([u], u.age > 18)
      end
      """

      %Mutare.Transform.Result{mutants: sites} =
        Mutare.transform_string(src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo}],
          expand_uses: true
        )

      boundary = Enum.find(sites, &(&1.mutated_code =~ ">= 18" and &1.mutator == :ecto))
      assert boundary.note =~ "a row whose value sits exactly on the bound"
    end
  end
end
