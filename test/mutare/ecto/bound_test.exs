defmodule Mutare.Ecto.BoundTest do
  use ExUnit.Case, async: true

  # Direct unit tests for the `:bound` bump catalog. The bumps are exercised end to end through
  # the host (`query_test.exs`/`clause_test.exs`/`host_test.exs`); here the two contracts the
  # routing classifier and the host lean on are pinned on their own: the off-by-one arithmetic
  # (`n+1` always, `n-1` only while it stays non-negative) and `literal?/1` being exactly
  # `bumps/1` non-emptiness — the "routing and host agree by definition" guarantee.

  alias Mutare.Ecto.Bound

  defp bumped(value) do
    for mutation <- Bound.bumps(value) do
      {:ok, n} = Mutare.AST.literal_value(mutation.node)
      n
    end
  end

  describe "bumps/1" do
    test "a positive literal bumps both ways, tagged :bound" do
      assert Enum.sort(bumped({:__block__, [token: "10"], [10]})) == [9, 11]
      assert Enum.all?(Bound.bumps(10), &(&1.variant == [:bound]))
    end

    test "n = 1 still bumps both ways — the lower bump reaches 0, which is valid SQL" do
      assert Enum.sort(bumped(1)) == [0, 2]
    end

    test "n = 0 bumps up only — a negative bound is invalid SQL" do
      assert bumped(0) == [1]
    end

    test "anything that is not a literal integer yields no bumps" do
      # A pinned/expression bound is mutated where it is bound, in ordinary Elixir.
      assert Bound.bumps({:^, [], [{:n, [], nil}]}) == []
      assert Bound.bumps({:__block__, [], [:ten]}) == []
      assert Bound.bumps(nil) == []
    end
  end

  describe "literal?/1" do
    test "is exactly bumps/1 non-emptiness" do
      for value <- [10, 1, 0, {:__block__, [token: "5"], [5]}, {:^, [], [{:n, [], nil}]}, nil] do
        assert Bound.literal?(value) == (Bound.bumps(value) != [])
      end
    end
  end
end
