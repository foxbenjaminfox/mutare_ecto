defmodule Mutare.Ecto.FragmentWalkParityTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Fragment

  # `Fragment` walks a condition twice, in two separate recursive functions: `mutants/1` (the SQL
  # catalog's single-point mutants) and `islands/1` (the `^`-pin interiors it hands to core). They
  # MUST make the same descend/don't-descend decision at every node — otherwise a real pin island
  # goes uncollected (a false negative) or a pin gets mutated as SQL the catalog does not own. The
  # moduledoc of `islands/1` leans on this agreement ("a caller cannot reach an island the catalog
  # would not have walked past"), so it is worth a guard.
  #
  # Two of the three descent decisions are already structurally single-sourced and don't need a
  # probe here: the nested-author-macro rule (both walks route per-argument descent through
  # `Mutare.Ecto.Descent`) and the subquery-interior recursion (both delegate to the same
  # `Mutare.Ecto.Subquery` entry points — and its interiors only resolve under the full transform
  # pipeline, so that half is exercised end-to-end in `subcontract_test.exs`/`exotic_query_test.exs`,
  # not here). What is left, and what each walk still pattern-matches *independently*, is the
  # STRUCTURAL recognition: `is_nil` (never entered), the `in` membership operands (entered), and a
  # written list (entered). That is what this test pins.
  #
  # The probe: at one test position each fixture places either a lone `^v` pin or a lone integer
  # literal. `islands/1` surfaces the pin *iff* it descended to that position; `mutants/1` yields an
  # `:integer_literal` mutant *iff* it descended to the same position (that literal is the fixture's
  # only integer). When the two walks agree, both answers equal `descend?`.
  @fixtures [
    %{
      desc: "comparison operand",
      descend?: true,
      pinned: "u.age > ^v",
      literal: "u.age > 4242"
    },
    %{
      desc: "connective operand",
      descend?: true,
      pinned: "u.a and u.b > ^v",
      literal: "u.a and u.b > 4242"
    },
    %{
      desc: "is_nil argument (never entered — value mutants preserve NULL-ness)",
      descend?: false,
      pinned: "is_nil(u.a + ^v)",
      literal: "is_nil(u.a + 4242)"
    },
    %{
      desc: "membership left operand",
      descend?: true,
      pinned: "u.a + ^v in [u.x, u.y]",
      literal: "u.a + 4242 in [u.x, u.y]"
    },
    %{
      desc: "not-membership left operand (reached through the outer `not`)",
      descend?: true,
      pinned: "u.a + ^v not in [u.x, u.y]",
      literal: "u.a + 4242 not in [u.x, u.y]"
    },
    %{
      desc: "written in-list element",
      descend?: true,
      pinned: "u.a in [^v]",
      literal: "u.a in [4242]"
    }
  ]

  for %{desc: desc, pinned: pinned, literal: literal, descend?: descend?} <- @fixtures do
    test "#{desc}: both walks #{if(descend?, do: "descend", else: "stop")} in step" do
      assert island_surfaced?(unquote(pinned)) == unquote(descend?),
             "islands/1 disagreed with the expected descent for: #{unquote(pinned)}"

      assert literal_descended?(unquote(literal)) == unquote(descend?),
             "mutants/1 disagreed with the expected descent for: #{unquote(literal)}"
    end
  end

  # Whether `islands/1` surfaced the fixture's single pin — i.e. its walk descended to that position.
  defp island_surfaced?(src), do: src |> Sourceror.parse_string!() |> Fragment.islands() != []

  # Whether `mutants/1` produced an `:integer_literal` mutant — i.e. its walk descended to the
  # fixture's single integer literal. Any other family (a comparison/membership flip on an outer
  # node) is not descent to the probe position, so it is ignored.
  defp literal_descended?(src) do
    src
    |> Sourceror.parse_string!()
    |> Fragment.mutants()
    |> Enum.any?(&(&1.family == :integer_literal))
  end
end
