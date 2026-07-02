defmodule Mutare.Ecto.ASTTest do
  use ExUnit.Case, async: true

  # Direct unit tests for the small Sourceror AST helpers. Elsewhere these are exercised only
  # *indirectly* (through the sub-mutators that call them), which leaves their type-discrimination
  # contracts under-pinned. Here each helper is driven on its own — both the value it extracts and
  # the wrapping it must (not) see through. Emission helpers live in core's `Mutare.AST` (tested
  # there); this module keeps only the plugin's typed readers and query-specific predicates.

  alias Mutare.Ecto.AST

  describe "atom_value/1" do
    test "reads the atom out of a Sourceror-wrapped or bare atom" do
      assert AST.atom_value({:__block__, [], [:active]}) == :active
      assert AST.atom_value(:active) == :active
    end

    test "a block wrapping a non-atom is not an atom literal" do
      # The `is_atom` filter over core's `literal_value/1` discriminates: an integer block reads
      # as `nil`, not as the integer — only an atom is an atom value.
      assert AST.atom_value({:__block__, [], [5]}) == nil
    end

    test "anything that is neither an atom nor an atom block is nil (the fallback)" do
      assert AST.atom_value([1, 2]) == nil
      assert AST.atom_value({:u, [], nil}) == nil
      assert AST.atom_value("active") == nil
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
end
