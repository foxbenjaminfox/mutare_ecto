defmodule Mutare.Ecto.ChangesetTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # A stage drop is diffed over the pipe up to the stage and collapses to its upstream: the
  # stage's text is in the original and gone from the replacement.
  defp stage_drop?({original, mutated}, stage),
    do: original =~ stage and not (mutated =~ stage)

  test "drops each validator in a pipeline, collapsing the pipe to the stage's upstream" do
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
    assert Enum.any?(diffs, &stage_drop?(&1, "validate_required"))
    assert Enum.any?(diffs, &stage_drop?(&1, "validate_length"))
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

    # Pin the origin so the drop is verified to be the constraint stage, not some other node.
    assert ecto_diffs(src) == [{"cs |> unique_constraint(:email)", "cs"}]
  end

  test "leaves content-producing calls (cast/change/put_change) untouched" do
    # The moduledoc contract: only *transparent* validators/constraints (and the Repo-time hooks)
    # are dropped — never a content-producing call, since dropping `cast`/`change`/`put_change`
    # changes the changeset's *data*, a different (and unsafe) mutation. Pins that `family/1`
    # tags those as nil (no drop) rather than falling through to a drop family.
    src = """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs, attrs) do
        cs
        |> cast(attrs, [:name])
        |> change(%{role: :user})
        |> put_change(:active, true)
        |> validate_required([:name])
      end
    end
    """

    diffs = ecto_diffs(src)

    # Exactly one drop — the lone transparent validator — and nothing else in the pipeline.
    assert [diff] = diffs
    assert stage_drop?(diff, "validate_required")

    # None of the content-producing stages are ever a drop candidate.
    for stage <- ["cast(", "change(", "put_change("] do
      refute Enum.any?(diffs, &stage_drop?(&1, stage))
    end
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

    # Exactly the three named transparent validators drop — each origin pinned so a *different*
    # set of three drops (same count, wrong stages) can't pass.
    diffs = ecto_diffs(src)
    assert length(diffs) == 3
    assert Enum.any?(diffs, &stage_drop?(&1, ~s|validate_exclusion(:name, ~w(admin))|))
    assert Enum.any?(diffs, &stage_drop?(&1, "validate_acceptance(:terms)"))
    assert Enum.any?(diffs, &stage_drop?(&1, "unsafe_validate_unique(:email, MyApp.Repo)"))
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
      hooks =
        ecto_diffs(@hook_src, mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:hook_drop]}])

      assert length(hooks) == 2
      assert Enum.any?(hooks, &stage_drop?(&1, "prepare_changes"))
      assert Enum.any?(hooks, &stage_drop?(&1, "optimistic_lock"))
    end

    test "the hooks are NOT in :validation_drop" do
      validators =
        ecto_diffs(@hook_src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:validation_drop]}]
        )

      assert validators == []
    end
  end

  describe "exotic pipelines (assoc/embed casts, anonymous-fn validators)" do
    @exotic_src """
    defmodule Acct do
      import Ecto.Changeset

      def changeset(user, attrs) do
        user
        |> cast(attrs, [:name, :age])
        |> cast_assoc(:posts, with: &post_changeset/2)
        |> cast_embed(:settings, required: true)
        |> put_assoc(:tags, [])
        |> update_change(:name, &String.trim/1)
        |> validate_change(:age, fn :age, age ->
          if age < 0, do: [age: "must be non-negative"], else: []
        end)
        |> validate_required([:name])
      end

      def post_changeset(post, attrs), do: cast(post, attrs, [:title])
    end
    """

    test "assoc/embed casts and content updates are never dropped; validate_change is" do
      diffs = ecto_diffs(@exotic_src)

      # `cast_assoc`/`cast_embed`/`put_assoc`/`update_change` all *produce* changeset content —
      # dropping one changes the data, not a rule — so none is a drop candidate…
      for stage <- ["cast_assoc", "cast_embed", "put_assoc", "update_change"] do
        refute Enum.any?(diffs, &stage_drop?(&1, stage))
      end

      # …while `validate_change` — even carrying an anonymous fn — is a transparent validator
      # whose whole stage (closure included) drops, alongside validate_required.
      assert Enum.any?(diffs, fn {original, _mutated} = diff ->
               original =~ "fn :age" and stage_drop?(diff, "validate_change")
             end)

      assert Enum.any?(diffs, &stage_drop?(&1, "validate_required"))
      assert length(diffs) == 2
    end

    test "the exotic pipeline's metamutant compiles (closures survive the weave)" do
      assert_compiles(@exotic_src)
      assert_compiles(@exotic_src, mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}])
    end
  end

  describe "collapse + totality (direct mutations/2)" do
    defp cs_mutations(code) do
      Sourceror.parse_string!(code)
      |> Mutare.Ecto.Changeset.mutations(context())
      |> Enum.map(&{&1.family, Sourceror.to_string(&1.node)})
    end

    test "the drop collapses the stage to the changeset it threads" do
      assert cs_mutations("Ecto.Changeset.validate_required(cs, [:name])") ==
               [{:validation_drop, "cs"}]
    end

    test "a degenerate zero-arg changeset step yields no mutant, never a crash" do
      assert cs_mutations("Ecto.Changeset.validate_required()") == []
    end
  end
end
