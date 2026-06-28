defmodule Mutare.Ecto.BindingTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Binding

  # The shared binding-AST vocabulary the host and the positional reorder both build on. These pin
  # the primitives directly (they are also exercised end-to-end via host_test / binding_reorder_test).

  defp parse(code), do: Sourceror.parse_string!(code)

  describe "variable?/1" do
    test "true for a binding variable node, false for everything else" do
      assert Binding.variable?({:u, [], nil})
      assert Binding.variable?({:p, [line: 1], Elixir})

      # a field access, a named pair, the `...` anchor, and a literal are not variables.
      refute Binding.variable?(parse("u.id"))
      refute Binding.variable?({{:__block__, [], [:post]}, {:p, [], nil}})
      refute Binding.variable?(parse("..."))
      refute Binding.variable?(parse("1"))
    end

    test "a local call `f(args)` is not a variable (atom name but non-atom context)" do
      # The case the host/reorder guards lean on: `{:f, meta, [args]}` has an atom name but a list
      # context, so it must not read as a binding variable.
      refute Binding.variable?(parse("f(1)"))
    end
  end

  describe "reorderable_name/1" do
    test "returns ordinary variable names and excludes underscore-prefixed bindings" do
      assert Binding.reorderable_name({:u, [], nil}) == :u
      refute Binding.reorderable_name({:_, [], nil})
      refute Binding.reorderable_name({:_unused, [], nil})
      refute Binding.reorderable_name(parse("u.id"))
    end
  end

  describe "ellipsis?/1 and ellipsis/0" do
    test "ellipsis?/1 recognizes only the `...` node" do
      assert Binding.ellipsis?(parse("..."))
      assert Binding.ellipsis?(Binding.ellipsis())
      refute Binding.ellipsis?({:u, [], nil})
      refute Binding.ellipsis?(parse("u.id"))
    end

    test "ellipsis/0 is a clean-meta node that renders as `...`" do
      assert {:..., [], []} = Binding.ellipsis()
      assert Sourceror.to_string(Binding.ellipsis()) == "..."
    end
  end

  describe "entry?/1" do
    test "accepts positional, named, and ellipsis entries" do
      assert Binding.entry?({:u, [], nil})
      assert Binding.entry?({{:__block__, [], [:post]}, {:p, [], nil}})
      assert Binding.entry?({:..., [], nil})
    end

    test "rejects shorthand-like pairs whose value is not a binding variable" do
      refute Binding.entry?({{:__block__, [], [:active]}, {:__block__, [], [true]}})
      refute Binding.entry?({:not_a_binding, [], []})
    end
  end
end
