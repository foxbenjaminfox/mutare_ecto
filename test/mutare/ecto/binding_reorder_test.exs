defmodule Mutare.Ecto.BindingReorderTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Positional binding-reorder for every standalone/pipe query macro that takes a binding list —
  # `where`/`having` included (`Mutare.Ecto.BindingReorder`). A binding list maps names to bindings by
  # position, so transposing two positional entries (`[a, b]` → `[b, a]`) is a real behavioral mutant,
  # delivered **in place** by swapping the written list (the macro call is itself an expression), never
  # by rewriting the condition body. Named bindings (`comments: c`) are addressed by name and are never
  # moved. A `from` binding-list *source* (`[a, b] in q`) reorders at the whole-`from` level
  # (`Mutare.Ecto.Query`) — see the dedicated describe below.

  # The mutated whole-node renderings recorded under the `:ecto` family.
  defp mutated(src), do: src |> ecto_diffs() |> Enum.map(fn {_o, m} -> m end)

  describe "the standalone/pipe binding-list macros" do
    test "order_by (direct form) swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u, p], asc: [u.name, p.title])
      end
      """

      assert {"order_by(query, [u, p], asc: [u.name, p.title])",
              "order_by(query, [p, u], asc: [u.name, p.title])"} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "order_by (pipe form) swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u, p], asc: [u.name, p.title])
      end
      """

      assert {"order_by([u, p], asc: [u.name, p.title])",
              "order_by([p, u], asc: [u.name, p.title])"} in ecto_diffs(src)

      assert_compiles(src)
    end

    test "select swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: select(query, [u, p], {u.id, p.id})
      end
      """

      assert {"select(query, [u, p], {u.id, p.id})", "select(query, [p, u], {u.id, p.id})"} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end

    test "group_by swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: group_by(query, [u, p], [u.id, p.id])
      end
      """

      assert {"group_by(query, [u, p], [u.id, p.id])", "group_by(query, [p, u], [u.id, p.id])"} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end

    test "distinct swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: distinct(query, [u, p], [u.id, p.id])
      end
      """

      assert {"distinct(query, [u, p], [u.id, p.id])", "distinct(query, [p, u], [u.id, p.id])"} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end

    test "join swaps the bindings in its (index-2) binding list" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: join(query, :inner, [u, p], f in "foo", on: u.id == p.id)
      end
      """

      assert {~s|join(query, :inner, [u, p], f in "foo", on: u.id == p.id)|,
              ~s|join(query, :inner, [p, u], f in "foo", on: u.id == p.id)|} in ecto_diffs(src)

      assert_compiles(src)
    end
  end

  describe "what does (and doesn't) get swapped" do
    test "a named binding is left in place; only the positional siblings transpose" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u, p, comments: c], asc: [u.name, p.title, c.body])
      end
      """

      # u/p transpose, the named `comments: c` stays put…
      assert Enum.any?(mutated(src), &(&1 =~ "[p, u, comments: c]"))
      # …and nothing ever moves `c` into a positional slot.
      refute Enum.any?(mutated(src), &(&1 =~ "[c," or &1 =~ "comments: c, "))
      assert_compiles(src)
    end

    test "three positional bindings yield every pairwise transposition" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: select(query, [u, p, c], {u.id, p.id, c.id})
      end
      """

      muts = mutated(src)
      assert Enum.any?(muts, &(&1 =~ "[p, u, c]"))
      assert Enum.any?(muts, &(&1 =~ "[c, p, u]"))
      assert Enum.any?(muts, &(&1 =~ "[u, c, p]"))
      assert_compiles(src)
    end

    test "a single positional binding yields no swap" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u], asc: u.name)
      end
      """

      refute Enum.any?(mutated(src), &(&1 =~ ~r/order_by\(query, \[\w+, /))
      assert_compiles(src)
    end

    test "unused bindings still reorder, matching core's pattern-swap policy" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u, p], asc: u.name)
      end
      """

      # Only `u` is used, so this is an equivalent mutant that exposes a redundant declaration.
      assert {"order_by(query, [u, p], asc: u.name)", "order_by(query, [p, u], asc: u.name)"} in ecto_diffs(
               src
             )

      assert_compiles(src)
    end

    test "underscore-prefixed bindings never participate in a reorder" do
      assert reorder_renders("select(query, [_ignored, a, b], [a.x, b.y])") == [
               "select(query, [_ignored, b, a], [a.x, b.y])"
             ]

      assert reorder_renders("select(query, [_left, _right], 1)") == []
    end
  end

  describe "the `...` anchor across positions (every combination with positional bindings)" do
    # The `...` tail-anchor is never itself a positional (`Binding.variable?/1` rejects it), so it
    # never moves: the positional bindings transpose *around* it, wherever it sits. These pin the swap
    # for the anchor in each position and in combination with named and underscore-prefixed binds.
    # The catalog is asserted exactly (`reorder_renders`, defined below); a final
    # case proves every anchor-position mutant is valid Ecto that compiles.

    test "leading anchor `[..., a, b]` swaps the positionals, anchor stays first" do
      assert reorder_renders("select(q, [..., a, b], [a.x, b.y])") ==
               ["select(q, [..., b, a], [a.x, b.y])"]
    end

    test "trailing anchor `[a, b, ...]` swaps the positionals, anchor stays last" do
      assert reorder_renders("select(q, [a, b, ...], [a.x, b.y])") ==
               ["select(q, [b, a, ...], [a.x, b.y])"]
    end

    test "interior anchor `[a, ..., b]` transposes the front- and tail-anchored bindings" do
      # `a` binds the query's first source, `b` its last; the swap (`[b, ..., a]`) exchanges which
      # source each reads — a genuine reorder across the `...`, not a no-op.
      assert reorder_renders("select(q, [a, ..., b], [a.x, b.y])") ==
               ["select(q, [b, ..., a], [a.x, b.y])"]
    end

    test "three positionals around a leading anchor yield every pairwise transposition" do
      assert reorder_renders("select(q, [..., a, b, c], [a.x, b.y, c.z])") == [
               "select(q, [..., b, a, c], [a.x, b.y, c.z])",
               "select(q, [..., c, b, a], [a.x, b.y, c.z])",
               "select(q, [..., a, c, b], [a.x, b.y, c.z])"
             ]
    end

    test "a lone positional beside the anchor (`[..., a]`) yields no swap" do
      # One positional, so there is no pair to transpose — the `...` is never counted as one.
      assert reorder_renders("select(q, [..., a], [a.x])") == []
    end

    test "a positional + named binding around the anchor never swaps (one positional only)" do
      # `comments: c` is name-addressed (never moved) and `a` is the lone positional, so there is no
      # positional pair; the `...` and the named pair both ride untouched.
      assert reorder_renders("order_by(q, [a, ..., comments: c], asc: [a.x, c.y])") == []
    end

    test "an unused binding still reorders across the anchor" do
      assert reorder_renders("select(q, [a, ..., b], [a.x])") == [
               "select(q, [b, ..., a], [a.x])"
             ]
    end

    test "every anchor-position mutant is valid Ecto that compiles" do
      src = """
      defmodule M do
        import Ecto.Query

        def lead(query), do: select(query, [..., a, b], {a.id, b.id})
        def trail(query), do: select(query, [a, b, ...], {a.id, b.id})
        def interior(query), do: select(query, [a, ..., b], {a.id, b.id})
      end
      """

      muts = mutated(src)
      assert Enum.any?(muts, &(&1 =~ "select(query, [..., b, a]"))
      assert Enum.any?(muts, &(&1 =~ "select(query, [b, a, ...]"))
      assert Enum.any?(muts, &(&1 =~ "select(query, [b, ..., a]"))
      assert_compiles(src)
    end
  end

  describe "where/having reorder in place too" do
    test "where swaps its binding list in place (not a host reference swap of the body)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [u, p], u.id == p.id)
      end
      """

      muts = mutated(src)
      # The binding list is swapped in place, like every other binding-list macro…
      assert Enum.any?(muts, &(&1 =~ "where(query, [p, u]"))
      # …and the condition body is left exactly as written (no `p.id == u.id` reference swap).
      refute Enum.any?(muts, &(&1 == "p.id == u.id"))
      assert_compiles(src)
    end

    test "having swaps its binding list in place" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: having(query, [u, p], u.id > p.id)
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "having(query, [p, u]"))
      assert_compiles(src)
    end

    test "a pinned dynamic has its own scope but the redundant outer list still reorders" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [a, b], ^dynamic([a, b], a.id > b.id))
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "where(query, [b, a]"))
      assert_compiles(src)
    end
  end

  describe "a from binding-list source reorders at the whole-from level" do
    # The author wrote `[a, b]` at the whole-`from` level (the source), so the swap belongs there —
    # one whole-`from` mutant rewriting the source declaration, never a per-clause body rewrite. The
    # swap reaches across clauses: a pair referenced in *different* clauses still reorders.
    test "swaps a binding list in the source-only from form" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([a, b] in query)
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "[b, a] in query"))
      assert_compiles(src)
    end

    test "swaps the source binding list, leaving the clause bodies untouched" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from([a, b] in query, where: a.x == b.y, having: a.z > b.w, select: a.id)
        end
      end
      """

      muts = mutated(src)
      # The source declaration swaps as a whole-`from` rewrite (reported at the source clause)…
      assert Enum.any?(muts, &(&1 =~ "[b, a] in query"))
      # …and no clause body is reference-swapped (the bodies ride along verbatim).
      refute Enum.any?(muts, &(&1 =~ "b.x == a.y"))
      assert_compiles(src)
    end

    test "reorders only the positional bindings of a mixed source list, leaving named ones alone" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from([u, p, comments: c] in query,
            where: u.age > p.views and c.flag > u.score,
            select: u.id)
        end
      end
      """

      muts = mutated(src)

      # The positional `u`/`p` transpose at the whole-`from` level; the named `comments: c` stays put.
      assert Enum.any?(muts, &(&1 =~ "[p, u, comments: c] in query"))
      # Nothing ever moves `c` into a positional slot or reorders it.
      refute Enum.any?(muts, &(&1 =~ "[c," or &1 =~ "comments: c, "))
      assert_compiles(src)
    end

    test "a scalar source and synthesized join bindings never reorder" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(a in MyApp.Post, join: b in MyApp.Post, on: a.id < b.id, select: a.id)
      end
      """

      # No author-written positional list at any level, so nothing transposes.
      refute Enum.any?(mutated(src), &(&1 =~ "[b, a]"))
      assert_compiles(src)
    end

    test "a pinned dynamic does not suppress a redundant source-list reorder" do
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          from([a, b] in query, where: ^dynamic([a, b], a.id > b.id), select: 1)
        end
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "[b, a] in query"))
      assert_compiles(src)
    end

    test "underscore-prefixed source bindings never participate in a reorder" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([_ignored, a, b] in query, select: {a.id, b.id})
      end
      """

      muts = mutated(src)
      assert Enum.any?(muts, &(&1 =~ "[_ignored, b, a] in query"))
      refute Enum.any?(muts, &(&1 =~ "[a, _ignored" or &1 =~ "[b, a, _ignored"))
      assert_compiles(src)
    end
  end

  describe "the reorder catalog through the transform contract" do
    defp reorder_renders(code) do
      src = """
      defmodule ReorderFixture do
        import Ecto.Query
        def q(query), do: #{code}
      end
      """

      src
      |> ecto_diffs(mutators: [{Mutare.Ecto, families: [:binding_reorder]}])
      |> Enum.map(fn {_original, mutated} -> mutated end)
    end

    test "two positional bindings yield exactly one swap (the unordered pair, once)" do
      # `[a, b]` → the lone transposition `[b, a]`. The pair is visited exactly once:
      # not as the (a,a)/(b,b) no-op self-swaps, nor as both (a,b) and (b,a). A count of one is the
      # discriminator (the `i < j` bound), so it is asserted as an exact, single-element list.
      assert reorder_renders("select(query, [a, b], [a.x, b.y])") == [
               "select(query, [b, a], [a.x, b.y])"
             ]
    end

    test "a list of field accesses / atoms is not a binding list (no swap, no crash)" do
      # BindingList.find/1 tests every list argument through BindingList.parse/1; a select/group_by
      # list of field accesses or field names has no binding entries, so it is never mistaken for a
      # binding list and the non-binding shape does not raise.
      assert reorder_renders("select(query, [u.x, u.y])") == []
      assert reorder_renders("group_by(query, [:id, :name])") == []
    end
  end
end
