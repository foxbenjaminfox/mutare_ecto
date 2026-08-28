defmodule Mutare.Ecto.FragmentDescentTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Config, Fragment}

  @config Config.parse!([])

  # `Fragment`'s two readers — `mutants/2` (the SQL catalog's single-point mutants) and
  # `islands/1` (the `^`-pin interiors it hands to core) — read the positions of ONE walk
  # (`Mutare.Ecto.Walk.positions/3`) under the catalog's one descent rule (`children/2`), so they
  # agree at every node by construction: neither descends on its own. (They used to be two
  # hand-rolled copies of the traversal, and this file guarded their parity.) What is still worth
  # pinning is the descent **policy** itself — the decisions a condition's SQL semantics dictate,
  # which a well-meaning edit to `children/2` could silently flip: `is_nil` claims its whole
  # argument (never entered — its one interior mutant, the coalesce drop, is read by the unit's
  # own narrowed walk in `local/3`, not by the shared descent), the `in` operands are entered
  # (through a written `not` too), and a written list's elements are entered. A wrong turn there is a false negative (a real pin island
  # uncollected, a real literal never mutated) or a pin mutated as SQL the catalog does not own.
  #
  # The nested-author-macro rule is `Mutare.Ecto.Walk`'s, and the subquery-interior recursion is
  # `Mutare.Ecto.Subquery`'s (its interiors only resolve under the full transform pipeline, so that
  # half is exercised end-to-end in `subcontract_test.exs`/`exotic_query_test.exs`, not here).
  #
  # The probe: at one test position each fixture places either a lone `^v` pin or a lone integer
  # literal. `islands/1` surfaces the pin *iff* the walk reached that position; `mutants/2` yields an
  # `:integer_literal` mutant *iff* it reached the same position (that literal is the fixture's
  # only integer). Both readers are asserted, so a reader that grew a descent of its own — or lost
  # one — fails here too.
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
      desc:
        "is_nil argument (never entered — value mutants preserve NULL-ness; the coalesce drop is the unit's, not the walk's)",
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
    },
    %{
      desc: "tuple-comparison element (Ecto's row-value comparison — the tuple is transparent)",
      descend?: true,
      pinned: "{u.a, u.b} > {^v, u.c}",
      literal: "{u.a, u.b} > {4242, u.c}"
    }
  ]

  for %{desc: desc, pinned: pinned, literal: literal, descend?: descend?} <- @fixtures do
    test "#{desc}: both readers #{if(descend?, do: "descend", else: "stop")} in step" do
      assert island_surfaced?(unquote(pinned)) == unquote(descend?),
             "islands/1 disagreed with the expected descent for: #{unquote(pinned)}"

      assert literal_descended?(unquote(literal)) == unquote(descend?),
             "mutants/2 disagreed with the expected descent for: #{unquote(literal)}"
    end
  end

  # Whether `islands/1` surfaced the fixture's single pin — i.e. the walk reached that position.
  defp island_surfaced?(src), do: src |> Sourceror.parse_string!() |> Fragment.islands() != []

  # Whether `mutants/2` produced an `:integer_literal` mutant — i.e. the walk reached the
  # fixture's single integer literal. Any other family (a comparison/membership flip on an outer
  # node) is not descent to the probe position, so it is ignored.
  defp literal_descended?(src) do
    src
    |> Sourceror.parse_string!()
    |> Fragment.mutants(@config)
    |> Enum.any?(&(&1.family == :integer_literal))
  end
end
