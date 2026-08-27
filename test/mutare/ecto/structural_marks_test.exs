defmodule Mutare.Ecto.StructuralMarksTest do
  # The plugin's `argument_marks/1` declarations (`c:Mutare.Mutator.argument_marks/1`, the shared
  # `:structural` label): `apply_action/2`'s and `apply_action!/2`'s action atom names which
  # lifecycle the caller claims — never consulted on the success path, only stamped as
  # `changeset.action` on the error path — so core's value families must not perturb it when they
  # run alongside the plugin. The plugin ships that knowledge; no per-family `:skip_arguments`
  # user config needed.
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  @atom Mutare.Mutators.AtomLiteral

  test "apply_action's action atom is held back from core's :atom family" do
    src = """
    defmodule Acct do
      def save(cs), do: Ecto.Changeset.apply_action(cs, :update)
    end
    """

    assert diffs(src, mutators: [@atom, {Mutare.Ecto, repo: MyApp.Repo}]) == []

    # Not vacuous: without the plugin (and so without its marks), the same atom mutates.
    assert [{:atom, ":update", ":mutare"}] = diffs(src, mutators: [@atom])
  end

  test "the bang twin and the piped spellings are pinned too (effective-index accounting)" do
    for call <- [
          "Ecto.Changeset.apply_action!(cs, :insert)",
          "cs |> Ecto.Changeset.apply_action(:insert)",
          "cs |> Ecto.Changeset.apply_action!(:insert)"
        ] do
      src = """
      defmodule Acct do
        def save(cs), do: #{call}
      end
      """

      assert diffs(src, mutators: [@atom, {Mutare.Ecto, repo: MyApp.Repo}]) == [],
             "expected the action atom held back in `#{call}`"

      # Not vacuous: the atom family does reach this spelling when the marks are absent, so the
      # empty list above is the mark landing — not the family failing to descend a pipe/bang form.
      assert [{:atom, ":insert", ":mutare"}] = diffs(src, mutators: [@atom]),
             "expected the bare atom family to mutate `#{call}` without the plugin"
    end
  end

  test "an imported call resolves like any call-family match" do
    src = """
    defmodule Acct do
      import Ecto.Changeset
      def save(cs), do: apply_action(cs, :update)
    end
    """

    assert diffs(src, mutators: [@atom, {Mutare.Ecto, repo: MyApp.Repo}]) == []

    # Not vacuous: the bare atom family mutates the imported spelling too.
    assert [{:atom, ":update", ":mutare"}] = diffs(src, mutators: [@atom])
  end

  test "a sibling atom outside the pinned position still mutates — the pin is positional" do
    src = """
    defmodule Acct do
      def save(cs), do: {Ecto.Changeset.apply_action(cs, :update), :other}
    end
    """

    assert [{:atom, ":other", ":mutare"}] =
             diffs(src, mutators: [@atom, {Mutare.Ecto, repo: MyApp.Repo}])
  end
end
