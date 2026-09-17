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
    test "names a plain positional entry, excluding underscore-prefixed bindings" do
      assert Binding.reorderable_name({:positional, {:u, [], nil}}) == :u
      refute Binding.reorderable_name({:positional, {:_, [], nil}})
      refute Binding.reorderable_name({:positional, {:_unused, [], nil}})
    end

    test "no other entry is reorderable: each is addressed by index or name, not list position" do
      refute Binding.reorderable_name(:ellipsis)
      refute Binding.reorderable_name({:indexed, {:u, [], nil}, 0})
      refute Binding.reorderable_name({:named, :post, {:u, [], nil}})
      refute Binding.reorderable_name({:interpolated, {:name, [], nil}, {:u, [], nil}})
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

  describe "placeholder/0" do
    test "is a clean `_` node: a positional entry that renders as `_` and is never reordered" do
      assert {:_, [], nil} = Binding.placeholder()
      assert Sourceror.to_string(Binding.placeholder()) == "_"
      assert {:ok, {:positional, _var} = entry} = Binding.parse(Binding.placeholder())
      refute Binding.reorderable_name(entry)
    end
  end

  # `parse/1` mirrors `Ecto.Query.Builder.escape_bind/1`, clause for clause and in its order.
  describe "parse/1 — the entry grammar" do
    # The one element of `[<code>]`, as Sourceror hands it to the plugin.
    defp element(code), do: code |> parse() |> Mutare.AST.unwrap_literal() |> hd()

    test "a positional variable and the `...` anchor" do
      assert {:ok, {:positional, {:u, _, nil}}} = Binding.parse(element("[u]"))
      assert Binding.parse(element("[...]")) == {:ok, :ellipsis}
      assert Binding.parse(Binding.ellipsis()) == {:ok, :ellipsis}
    end

    test "`...` is the anchor even with an atom context, where it has a variable's shape" do
      # Ecto tests the anchor first for the same reason: `{:..., [], nil}` (context `nil`) passes
      # `variable?/1` — `:...` and `nil` are both atoms.
      assert Binding.variable?({:..., [], nil})
      assert Binding.parse({:..., [], nil}) == {:ok, :ellipsis}
    end

    test "a named binding, in the keyword and the explicit-tuple spellings" do
      assert {:ok, {:named, :post, {:p, _, nil}}} = Binding.parse(element("[post: p]"))
      assert {:ok, {:named, :post, {:p, _, nil}}} = Binding.parse(element("[{:post, p}]"))
    end

    test "an indexed positional, with a literal non-negative index only" do
      assert {:ok, {:indexed, {:p, _, nil}, 2}} = Binding.parse(element("[{p, 2}]"))
      assert Binding.parse(element("[{p, -1}]")) == :error
      assert Binding.parse(element("[{p, 1.5}]")) == :error
      assert Binding.parse(element("[{p, index}]")) == :error
    end

    test "a variable on the left is read as indexed before named, as Ecto reads it" do
      # `{p, c}` is "`p` at index `c`" to Ecto — never "`c` named `p`". The index is not a
      # literal, so the entry is uninterpretable rather than misread as a named binding.
      assert Binding.parse(element("[{p, c}]")) == :error
    end

    test "an interpolated name: a variable or a module attribute, nothing that could run code twice" do
      assert {:ok, {:interpolated, {:name, _, nil}, {:p, _, nil}}} =
               Binding.parse(element("[{^name, p}]"))

      assert {:ok, {:interpolated, {:@, _, [{:name, _, nil}]}, {:p, _, nil}}} =
               Binding.parse(element("[{^@name, p}]"))

      assert Binding.parse(element("[{^name(), p}]")) == :error
      assert Binding.parse(element("[{^opts.name, p}]")) == :error
      assert Binding.parse(element("[{^:post, p}]")) == :error
    end

    test "rejects shorthand-like pairs and non-binding nodes" do
      assert Binding.parse(element("[active: true]")) == :error
      assert Binding.parse(element("[name: ^value]")) == :error
      assert Binding.parse(element("[u.id]")) == :error
      assert Binding.parse(element("[f(1)]")) == :error
      assert Binding.parse(element("[:post]")) == :error
    end
  end

  describe "positional?/1" do
    test "everything but the two named forms occupies a position" do
      assert Binding.positional?(:ellipsis)
      assert Binding.positional?({:positional, {:u, [], nil}})
      assert Binding.positional?({:indexed, {:u, [], nil}, 0})
      refute Binding.positional?({:named, :post, {:u, [], nil}})
      refute Binding.positional?({:interpolated, {:name, [], nil}, {:u, [], nil}})
    end
  end
end
