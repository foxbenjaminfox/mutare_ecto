defmodule Mutare.Ecto.RepoAggregateTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "swaps :sum to :avg on a directly-aliased Repo.aggregate" do
    src = """
    defmodule Stats do
      alias MyApp.Repo
      def total(q), do: Repo.aggregate(q, :sum, :amount)
    end
    """

    assert [{original, mutated}] = ecto_diffs(src)
    assert original =~ ":sum"
    assert mutated =~ ":avg"
    assert mutated =~ "Repo.aggregate"
  end

  test "swaps :min to :max in a piped aggregate (effective-arity aware)" do
    src = """
    defmodule Stats do
      alias MyApp.Repo
      def lo(q), do: q |> Repo.aggregate(:min, :amount)
    end
    """

    assert [{_original, mutated}] = ecto_diffs(src)
    assert mutated =~ ":max"
  end

  test "leaves :count alone (different arity contract)" do
    src = """
    defmodule Stats do
      alias MyApp.Repo
      def n(q), do: Repo.aggregate(q, :count)
    end
    """

    assert ecto_diffs(src) == []
  end

  test "does not fire on a non-repo aggregate call" do
    src = """
    defmodule Stats do
      def total(q), do: Other.aggregate(q, :sum, :amount)
    end
    """

    assert ecto_diffs(src) == []
  end

  test "does not fire when no repo is configured" do
    src = """
    defmodule Stats do
      alias MyApp.Repo
      def total(q), do: Repo.aggregate(q, :sum, :amount)
    end
    """

    assert ecto_diffs(src, mutators: [Mutare.Ecto]) == []
  end
end
