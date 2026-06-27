defmodule Mutare.Ecto.BindingReorderTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # Positional binding-reorder for every standalone/pipe query macro that takes a binding list
  # (`Mutare.Ecto.BindingReorder`). A binding list maps names to bindings by position, so
  # transposing two positional entries (`[a, b]` → `[b, a]`) is a real behavioral mutant, delivered
  # in place (the macro call is itself an expression). Named bindings (`comments: c`) are addressed
  # by name and are never moved; `where`/`having` keep getting their reorder via the host.

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

      assert Enum.any?(mutated(src), &(&1 =~ "order_by(query, [p, u]"))
      assert_compiles(src)
    end

    test "order_by (pipe form) swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> order_by([u, p], asc: [u.name, p.title])
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "order_by([p, u]"))
      assert_compiles(src)
    end

    test "select swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: select(query, [u, p], {u.id, p.id})
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "select(query, [p, u]"))
      assert_compiles(src)
    end

    test "group_by swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: group_by(query, [u, p], [u.id, p.id])
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "group_by(query, [p, u]"))
      assert_compiles(src)
    end

    test "distinct swaps its two positional bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: distinct(query, [u, p], [u.id, p.id])
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "distinct(query, [p, u]"))
      assert_compiles(src)
    end

    test "join swaps the bindings in its (index-2) binding list" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: join(query, :inner, [u, p], f in "foo", on: u.id == p.id)
      end
      """

      assert Enum.any?(mutated(src), &(&1 =~ "join(query, :inner, [p, u]"))
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

    test "a swap is suppressed when one of the two bindings is unreferenced (would be equivalent)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: order_by(query, [u, p], asc: u.name)
      end
      """

      # Only `u` is used; swapping `[u, p]` while `p` is unreferenced is not emitted.
      refute Enum.any?(mutated(src), &(&1 =~ "order_by(query, [p, u]"))
      assert_compiles(src)
    end
  end

  describe "the `...` anchor across positions (every combination with positional bindings)" do
    # The `...` tail-anchor is never itself a positional (`Binding.variable?/1` rejects it), so it
    # never moves: the positional bindings transpose *around* it, wherever it sits. These pin the swap
    # for the anchor in each position and in combination with named binds and the reference/arity
    # suppression rules. The catalog is asserted exactly (`reorder_renders`, defined below); a final
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

    test "the suppression rule still applies across the anchor (unreferenced binding ⇒ no swap)" do
      # `b` is unreferenced, so swapping `[a, ..., b]` would manufacture an equivalent mutant — not
      # emitted, exactly as without an anchor.
      assert reorder_renders("select(q, [a, ..., b], [a.x])") == []
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

  describe "where/having are not double-handled" do
    test "where still reorders via the host (reference swap), not an in-place binding-list swap" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [u, p], u.id == p.id)
      end
      """

      muts = mutated(src)
      # The host's reference swap is present…
      assert Enum.any?(muts, &(&1 == "p.id == u.id"))
      # …and there is no in-place binding-list swap for the condition macro.
      refute Enum.any?(muts, &(&1 =~ "where(query, [p, u]"))
      assert_compiles(src)
    end
  end

  describe "the reorder catalog directly (mutations/1)" do
    defp reorder_renders(code) do
      code
      |> query_macro_ast()
      |> Mutare.Ecto.BindingReorder.mutations(%{})
      |> Enum.map(fn {:binding_reorder, node} -> Sourceror.to_string(node) end)
    end

    test "two referenced positional bindings yield exactly one swap (the unordered pair, once)" do
      # `[a, b]` both referenced → the lone transposition `[b, a]`. The pair is visited exactly once:
      # not as the (a,a)/(b,b) no-op self-swaps, nor as both (a,b) and (b,a). A count of one is the
      # discriminator (the `i < j` bound), so it is asserted as an exact, single-element list.
      assert reorder_renders("select(q, [a, b], [a.x, b.y])") == ["select(q, [b, a], [a.x, b.y])"]
    end

    test "a list of field accesses / atoms is not a binding list (no swap, no crash)" do
      # find_binding_list tests every list argument with binding_entry?; a select/group_by list of
      # field accesses or field names has no variable entries, so it is never mistaken for a binding
      # list — the entry predicate's fallback must return false, not raise on the non-binding shape.
      assert reorder_renders("select(q, [u.x, u.y])") == []
      assert reorder_renders("group_by(q, [:id, :name])") == []
    end
  end
end
