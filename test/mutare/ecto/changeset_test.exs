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

  test "drops validate_exclusion / validate_acceptance / unsafe_validate_unique" do
    src = """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs) do
        cs
        |> validate_exclusion(:name, ~w(admin))
        |> validate_acceptance(:terms)
        |> unsafe_validate_unique(:email, MyApp.Repo)
      end
    end
    """

    diffs = ecto_diffs(src)
    assert length(diffs) == 3
    assert Enum.all?(diffs, fn {_o, mutated} -> mutated =~ "identity" end)
  end

  describe ":hook_drop (deferred Repo-time hooks, distinct from :validation_drop)" do
    @hook_src """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs) do
        cs
        |> prepare_changes(fn c -> c end)
        |> optimistic_lock(:lock_version)
      end
    end
    """

    test "drops prepare_changes and optimistic_lock under :hook_drop" do
      hooks = ecto_diffs(@hook_src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:hook_drop]}])
      assert length(hooks) == 2
      assert Enum.all?(hooks, fn {_o, mutated} -> mutated =~ "identity" end)

      originals = Enum.map(hooks, fn {original, _m} -> original end)
      assert Enum.any?(originals, &(&1 =~ "prepare_changes"))
      assert Enum.any?(originals, &(&1 =~ "optimistic_lock"))
    end

    test "the hooks are NOT in :validation_drop" do
      validators =
        ecto_diffs(@hook_src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:validation_drop]}])

      assert validators == []
    end
  end
end
