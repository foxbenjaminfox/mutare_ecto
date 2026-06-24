defmodule Mutare.Ecto.RepoWriteTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # `:persistence` (insert/update/delete → non-persisting `apply_action`) and `:on_conflict`
  # (`:nothing`→`:raise`). Both resolve the call against the configured repo and ride Mutare's
  # ordinary in-place selector; we assert the recorded logical diff and that the metamutant compiles.

  defp persistence(opts \\ []),
    do: [mutators: [{Mutare.Ecto, [repo: MyApp.Repo, families: [:persistence]] ++ opts}]]

  defp on_conflict(opts \\ []),
    do: [mutators: [{Mutare.Ecto, [repo: MyApp.Repo, families: [:on_conflict]] ++ opts}]]

  describe ":persistence — write → apply_action" do
    test "rewrites Repo.insert to apply_action(change(arg), :insert) — the struct-safe form" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def create(cs), do: Repo.insert(cs)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src, persistence())
      assert original =~ "Repo.insert(cs)"
      # Long call → Sourceror may wrap it across lines; assert on the parts.
      assert mutated =~ "Elixir.Ecto.Changeset.apply_action("
      assert mutated =~ "Elixir.Ecto.Changeset.change(cs)"
      assert mutated =~ ":insert"
      assert_compiles(src, persistence())
    end

    test "maps the bang twin to apply_action! and the action to the write" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def save!(cs), do: Repo.update!(cs)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      assert mutated =~ "apply_action!("
      assert mutated =~ ":update"
    end

    test "delete maps to apply_action(:delete)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def remove(record), do: Repo.delete(record)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      assert mutated =~ "apply_action("
      assert mutated =~ "Elixir.Ecto.Changeset.change(record)"
      assert mutated =~ ":delete"
    end

    test "insert_or_update is covered" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert_or_update(cs)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      assert mutated =~ "apply_action("
    end

    test "the piped form becomes a right-nested change/apply_action pipe stage" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def create!(cs), do: cs |> Repo.insert!()
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      assert mutated =~ "Elixir.Ecto.Changeset.change()"
      assert mutated =~ "apply_action!(:insert)"
      assert_compiles(src, persistence())
    end

    test "drops the write's opts (a non-persisting stub takes none)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def create(cs), do: Repo.insert(cs, returning: true, on_conflict: :nothing)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      refute mutated =~ "returning"
      refute mutated =~ "on_conflict"
    end

    test "leaves insert_all alone (bulk write, no changeset)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def bulk(rows), do: Repo.insert_all("users", rows)
      end
      """

      assert ecto_diffs(src, persistence()) == []
    end

    test "does not fire on a non-repo call of the same name" do
      src = """
      defmodule Accounts do
        def create(cs), do: Other.insert(cs)
      end
      """

      assert ecto_diffs(src, persistence()) == []
    end
  end

  describe ":on_conflict — :nothing → :raise" do
    test "flips an explicit on_conflict: :nothing, preserving the other opts" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert(cs, on_conflict: :nothing, conflict_target: :email)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src, on_conflict())
      assert original =~ "on_conflict: :nothing"
      assert mutated =~ "on_conflict: :raise"
      assert mutated =~ "conflict_target: :email"
    end

    test "fires on the bang twin and in the piped form" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert!(cs), do: cs |> Repo.insert!(on_conflict: :nothing)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, on_conflict())
      assert mutated =~ "on_conflict: :raise"
    end

    test "leaves a non-:nothing on_conflict alone (e.g. :replace_all needs a target)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert(cs, on_conflict: :replace_all)
      end
      """

      assert ecto_diffs(src, on_conflict()) == []
    end

    test "does not fire on update (no on_conflict option there)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def save(cs), do: Repo.update(cs, on_conflict: :nothing)
      end
      """

      assert ecto_diffs(src, on_conflict()) == []
    end
  end
end
