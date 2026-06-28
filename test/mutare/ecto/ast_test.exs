defmodule Mutare.Ecto.ASTTest do
  use ExUnit.Case, async: true

  # Direct unit tests for the small Sourceror AST helpers. Elsewhere these are exercised only
  # *indirectly* (through the sub-mutators that call them), which leaves their type-discrimination
  # and literal-shape contracts under-pinned. Here each helper is driven on its own — both the
  # value it extracts/emits and the wrapping it must (not) see through.

  alias Mutare.Ecto.AST

  describe "atom_value/1" do
    test "reads the atom out of a Sourceror-wrapped or bare atom" do
      assert AST.atom_value({:__block__, [], [:active]}) == :active
      assert AST.atom_value(:active) == :active
    end

    test "a block wrapping a non-atom is not an atom literal" do
      # The `is_atom` guard on the block clause discriminates: an integer block reads as `nil`,
      # not as the integer — only an atom is an atom value.
      assert AST.atom_value({:__block__, [], [5]}) == nil
    end

    test "anything that is neither an atom nor an atom block is nil (the fallback clause)" do
      assert AST.atom_value([1, 2]) == nil
      assert AST.atom_value({:u, [], nil}) == nil
      assert AST.atom_value("active") == nil
    end
  end

  describe "atom_literal/1" do
    test "emits a clean-meta atom block (no token, so the renderer re-emits the value)" do
      assert AST.atom_literal(:asc) == {:__block__, [], [:asc]}
    end
  end

  describe "int_value/1" do
    test "reads the integer out of a Sourceror-wrapped or bare integer" do
      assert AST.int_value({:__block__, [token: "18"], [18]}) == 18
      assert AST.int_value(18) == 18
    end

    test "a block wrapping a non-integer is not an integer literal" do
      assert AST.int_value({:__block__, [], [:active]}) == nil
    end

    test "anything that is neither an integer nor an integer block is nil" do
      assert AST.int_value(:active) == nil
      assert AST.int_value([1]) == nil
    end
  end

  describe "int_literal/1" do
    test "a non-negative integer renders via a token-carrying block" do
      assert AST.int_literal(18) == {:__block__, [token: "18"], [18]}
      assert AST.int_literal(0) == {:__block__, [token: "0"], [0]}
    end

    test "a negative integer is the unary-minus-over-literal shape" do
      # The `int < 0` clause owns negatives; the boundary is `< 0`, so `-1` itself must take it
      # (distinguishing `< 0` from `< -1`) and any negative must, too (distinguishing it from a
      # never-taken / dropped clause that would fall through to the bare-block clause).
      assert AST.int_literal(-1) == {:-, [], [{:__block__, [token: "1"], [1]}]}
      assert AST.int_literal(-5) == {:-, [], [{:__block__, [token: "5"], [5]}]}
    end
  end

  describe "keyword_key/1" do
    test "emits a keyword-formatted key block (renders as `key:`)" do
      assert AST.keyword_key(:limit) == {:__block__, [format: :keyword], [:limit]}
    end
  end

  describe "clean_var/1" do
    test "strips a variable node's metadata, keeping name and hygiene context" do
      assert AST.clean_var({:u, [line: 5, column: 2], nil}) == {:u, [], nil}
      assert AST.clean_var({:u, [line: 5], MyCtx}) == {:u, [], MyCtx}
    end
  end

  describe "module_key/1" do
    test "an Elixir-module alias becomes its segment path" do
      assert AST.module_key(MyApp.Repo) == [:MyApp, :Repo]
    end

    test "an Erlang-atom module is itself" do
      assert AST.module_key(:binary) == :binary
    end
  end
end
