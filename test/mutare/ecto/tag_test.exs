defmodule Mutare.Ecto.TagTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Tag

  describe "to_mutation/1" do
    test "to_mutation/1 only relays an already-final Mutation when it actually carries a producer" do
      # `to_mutation/1`'s `%Mutation{producer: producer} = relayed when not is_nil(producer)` clause is
      # the *only* clause that can ever match a bare `%Mutation{}` struct (the other clause
      # matches a `%Tag{}`) — so it isn't merely narrowing
      # an already-Mutation-shaped input, it's the contract that every relayed struct reaching here
      # is producer-set (as every real caller — `Mutare.Ecto.Dynamic`'s island sub-contract —
      # guarantees). A producer-less Mutation is a contract violation, and should fail loudly
      # rather than quietly pass through unrelayed.
      spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Arithmetic)
      relayed = Mutare.Mutator.Mutation.new(quote(do: 1 + 1), producer: spec)
      assert Tag.to_mutation(relayed) == relayed

      producerless = Mutare.Mutator.Mutation.new(quote(do: 1 + 1))

      assert_raise FunctionClauseError, fn ->
        Tag.to_mutation(producerless)
      end
    end
  end
end
