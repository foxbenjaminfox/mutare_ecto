defmodule Mutare.Ecto.JoinTypeTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Config, JoinType}

  # The shared join-kind catalog both spellings read (`Mutare.Ecto.Query`'s `left_join:` key swap,
  # `Mutare.Ecto.Clause`'s `join(q, :left, …)` qualifier swap). Their deliveries are covered in
  # `query_test.exs`/`clause_test.exs`, and their agreement at the engine in the spelling suite;
  # this pins the table itself.

  @portable Config.parse!([])
  @right_capable Config.parse!(dialects: [:postgres])
  @sources [:left, :right, :full]
  @never_a_source [:inner, :cross, :inner_lateral, :left_lateral, :cross_lateral, nil, :mutare]

  test "the flips narrow, or turn sideways — never widen" do
    assert JoinType.targets(:left, @portable) == [:inner]
    assert JoinType.targets(:full, @portable) == [:left]
    assert JoinType.targets(:right, @portable) == []

    assert JoinType.targets(:left, @right_capable) == [:inner, :right]
    assert JoinType.targets(:full, @right_capable) == [:left, :right]
    assert JoinType.targets(:right, @right_capable) == [:left]

    for qualifier <- @never_a_source, config <- [@portable, @right_capable] do
      assert JoinType.targets(qualifier, config) == []
    end
  end

  test "every qualifier a flip reads or writes has a `from` key, and the two conversions invert" do
    # `from_key/1` is a `Map.fetch!`: `Mutare.Ecto.Query` calls it on every target, so a target
    # added to a flip table without a key would raise on the first `from` that reached it.
    reachable =
      Enum.uniq(@sources ++ Enum.flat_map(@sources, &JoinType.targets(&1, @right_capable)))

    for qualifier <- reachable do
      assert qualifier |> JoinType.from_key() |> JoinType.qualifier() == qualifier
    end

    assert JoinType.from_key(:left) == :left_join
    # `join:` is Ecto's other spelling of `inner_join:`; an inner join is never a source, so
    # only the spelled-out key needs to read back.
    for key <- [:join, :cross_join, :left_lateral_join, :where],
        do: refute(JoinType.qualifier(key))
  end

  test "variant_labels/0 is the source-qualifier vocabulary" do
    # Every flip table's keys — pins the three label strings against a drifted/blanked/renamed
    # constant. `:inner` is never a flip source (widening is deliberately not offered — see
    # `Mutare.Ecto.Query`'s moduledoc), so it is not in this vocabulary. The raw contribution is
    # unordered and repeats `left` (a source in both tables); `Mutare.Ecto.variants/0` is where the
    # union is canonicalised (`Mutare.Ecto.Vocabulary`).
    assert Enum.sort(Enum.uniq(JoinType.variant_labels())) == ["full", "left", "right"]
    assert Enum.map(@sources, &JoinType.label/1) == ["left", "right", "full"]
  end
end
