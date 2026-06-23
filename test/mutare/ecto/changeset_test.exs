defmodule Mutare.Ecto.ChangesetTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "drops each validator in a pipeline, replacing the stage with identity" do
    src = """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs) do
        cs
        |> validate_required([:name])
        |> validate_length(:name, min: 2)
      end
    end
    """

    diffs = ecto_diffs(src)
    assert length(diffs) == 2
    assert Enum.all?(diffs, fn {_original, mutated} -> mutated =~ "identity" end)

    originals = Enum.map(diffs, fn {original, _mutated} -> original end)
    assert Enum.any?(originals, &(&1 =~ "validate_required"))
    assert Enum.any?(originals, &(&1 =~ "validate_length"))
  end

  test "collapses a directly-written validator to the changeset argument" do
    src = """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs), do: validate_required(cs, [:name])
    end
    """

    assert [{_original, mutated}] = ecto_diffs(src)
    assert mutated == "cs"
  end

  test "drops a constraint as well as a validator" do
    src = """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs), do: cs |> unique_constraint(:email)
    end
    """

    assert [{_original, mutated}] = ecto_diffs(src)
    assert mutated =~ "identity"
  end

  test "does not fire on a non-changeset call of the same name" do
    src = """
    defmodule Acct do
      def changeset(cs), do: cs |> validate_required([:name])
    end
    """

    assert ecto_diffs(src) == []
  end
end
