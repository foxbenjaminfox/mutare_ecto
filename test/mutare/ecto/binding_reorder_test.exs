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
end
