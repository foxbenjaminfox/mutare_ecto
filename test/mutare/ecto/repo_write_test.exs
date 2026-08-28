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

    test "stamps the configured repo, which apply_action alone would leave nil" do
      # A real write records the Repo on the error changeset (`put_repo_and_action/4`), so the
      # non-persisting stand-in has to as well or it diverges on the *invalid* path — the path the
      # mutation is not about. Alias-proof, like every module reference the plugin emits.
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def create(cs), do: Repo.insert(cs)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())

      assert mutated =~
               "Elixir.Map.replace!(Elixir.Ecto.Changeset.change(cs), :repo, Elixir.MyApp.Repo)"
    end

    test "the stamped repo follows the configured repo:, not the written alias" do
      src = """
      defmodule Accounts do
        alias MyApp.PgRepo, as: Repo
        def create(cs), do: Repo.insert(cs)
      end
      """

      opts = [mutators: [{Mutare.Ecto, repo: MyApp.PgRepo, families: [:persistence]}]]
      assert [{_o, mutated}] = ecto_diffs(src, opts)
      assert mutated =~ ":repo, Elixir.MyApp.PgRepo"
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

    test "insert_or_update reads its action at runtime, as Ecto does" do
      # The one write whose action is not fixed: Ecto routes it on the changeset data's state, so
      # a hard-coded atom would mis-stamp `changeset.action` on the error path (`:insert` where the
      # baseline said `:update`) and kill the mutant with tests that never persist anything.
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert_or_update(cs)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      assert mutated =~ "Elixir.Kernel.then("
      assert mutated =~ "fn changeset ->"
      assert mutated =~ "Elixir.Ecto.get_meta(changeset.data, :state) == :loaded"
      assert mutated =~ "do: :update"
      assert mutated =~ "else: :insert"
      assert_compiles(src, persistence())
    end

    test "the bang twin of insert_or_update keeps the same runtime action, through apply_action!" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert!(cs), do: cs |> Repo.insert_or_update!()
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, persistence())
      assert mutated =~ "Elixir.Ecto.Changeset.apply_action!("
      assert mutated =~ "Elixir.Ecto.get_meta(changeset.data, :state) == :loaded"
      assert_compiles(src, persistence())
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
      assert mutated =~ "|> Elixir.Map.replace!(:repo, Elixir.MyApp.Repo)"
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
    test "flips an explicit on_conflict: :nothing, dropping the now-forbidden conflict_target" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo

        def upsert(cs),
          do: Repo.insert(cs, returning: true, on_conflict: :nothing, conflict_target: :email)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src, on_conflict())
      assert original =~ "on_conflict: :nothing"
      assert mutated =~ "on_conflict: :raise"
      # `:raise` forbids a `conflict_target:` (Ecto raises `ArgumentError` on the combination
      # before any SQL), so the pair rides along only in the original — keeping it would make the
      # mutant crash on *every* insert instead of on the conflict path.
      refute mutated =~ "conflict_target"
      # …while an unrelated opt survives the rebuild untouched.
      assert mutated =~ "returning: true"
      # The changeset stays the *first* argument — the rebuild reassembles `init ++ [swapped]`,
      # not the reverse (which would emit `insert([on_conflict: …], cs)`, a malformed call).
      assert mutated =~ "insert(cs,"
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

    test "flips an explicit on_conflict: :raise to :nothing (the reverse swap)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert(cs, on_conflict: :raise)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src, on_conflict())
      assert original =~ "on_conflict: :raise"
      assert mutated =~ "on_conflict: :nothing"
    end

    test "flips on_conflict: :replace_all to :nothing, keeping the conflict_target" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert(cs, on_conflict: :replace_all, conflict_target: :email)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src, on_conflict())
      assert original =~ "on_conflict: :replace_all"
      assert mutated =~ "on_conflict: :nothing"
      # `:nothing` accepts a target, and the target still *arbitrates* (a conflict on another
      # unique constraint raises either way), so the author's arbiter is preserved.
      assert mutated =~ "conflict_target: :email"
    end

    test "fires on bulk insert_all (the other write that takes on_conflict)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def bulk(rows), do: Repo.insert_all("users", rows, on_conflict: :nothing)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src, on_conflict())
      assert original =~ "on_conflict: :nothing"
      assert mutated =~ "on_conflict: :raise"
      # The schema/entries args stay first — only the trailing opts pair flips.
      assert mutated =~ ~s(insert_all("users", rows,)
    end

    test "the conflict_target drop is value-shape-agnostic (a list target on insert_all)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo

        def bulk(rows) do
          Repo.insert_all("users", rows, on_conflict: :nothing, conflict_target: [:email, :org_id])
        end
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, on_conflict())
      assert mutated =~ "on_conflict: :raise"
      refute mutated =~ "conflict_target"
    end

    test "swaps each source to exactly one distinct target (no reverse/extra mutants)" do
      # `:nothing` yields only `:raise` — not also a `:replace_all` mutant — and `:replace_all` is a
      # swap source only, so it never appears as a *target* anywhere (the target-less-crash guard).
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert(cs, on_conflict: :nothing)
      end
      """

      assert [{_o, mutated}] = ecto_diffs(src, on_conflict())
      assert mutated =~ "on_conflict: :raise"
      refute mutated =~ "on_conflict: :replace_all"
    end

    test "leaves a non-atom on_conflict alone (e.g. a {:replace, fields} tuple)" do
      src = """
      defmodule Accounts do
        alias MyApp.Repo
        def upsert(cs), do: Repo.insert(cs, on_conflict: {:replace, [:name]})
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

  describe "totality + gate precision (direct mutations/2)" do
    defp write_mutations(code, pipe_mode) do
      Mutare.Ecto.RepoWrite.mutations(
        Sourceror.parse_string!(code),
        context(pipe_mode: pipe_mode)
      )
    end

    test "a degenerate zero-arg write yields no mutant, never a crash" do
      # `Repo.insert()` with no changeset hits the empty-args/unpiped path: apply_action returns
      # nil and wrap(nil) drops it, so the mutator stays total — `[]`, not a nil-node `:persistence`
      # mutant nor a FunctionClauseError — on a write node it is offered but cannot rewrite.
      assert write_mutations("MyApp.Repo.insert()", :unpiped) == []
    end

    test "the on_conflict swap keys off the on_conflict option, not any :nothing-valued pair" do
      # A non-on_conflict option that happens to be valued `:nothing` must not be flipped to
      # `:raise` — the gate is the *key*, not merely the value.
      muts = write_mutations("MyApp.Repo.insert(cs, log: :nothing)", :unpiped)
      refute Enum.any?(muts, &(&1.family == :on_conflict))
    end
  end
end
