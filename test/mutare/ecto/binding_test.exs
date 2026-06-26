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

  describe "unwrap_list/1" do
    test "returns the element list of a block-wrapped or bare list, nil otherwise" do
      # Sourceror block-wraps a parsed list literal; unwrap_list peels it.
      assert [a, b] = Binding.unwrap_list(parse("[a, b]"))
      assert Binding.variable?(a) and Binding.variable?(b)

      # a bare list passes through.
      assert Binding.unwrap_list([{:a, [], nil}]) == [{:a, [], nil}]

      # a lone variable and any non-list yield nil.
      assert Binding.unwrap_list({:u, [], nil}) == nil
      assert Binding.unwrap_list(parse("u.id")) == nil
    end
  end
end
