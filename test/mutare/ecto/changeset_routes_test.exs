defmodule Mutare.Ecto.ChangesetRoutesTest do
  # The plugin's `:routing` registration of every changeset stage (`Mutare.Ecto.Changeset.Routing`):
  # a written field atom, `validate_number`'s option keys, and a written `validate_length` `count:`
  # mode — the positions where a core swap is a crash, not a mutant — are held back from core's
  # families when the plugin runs alongside them; everything else in a stage stays an ordinary
  # expression. Each case pairs the routed run with the un-routed control, so an empty result is
  # the route landing, never a family failing to reach the spelling.
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  @atom Mutare.Mutators.AtomLiteral
  @integer Mutare.Mutators.IntegerLiteral
  @plugin {Mutare.Ecto, repo: MyApp.Repo}

  defp atom_diffs(src, mutators) do
    for {:atom, original, mutated} <- diffs(src, mutators: mutators), do: {original, mutated}
  end

  defp src(stage) do
    """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs), do: #{stage}
    end
    """
  end

  test "a written field atom is held back — in the direct and piped forms" do
    for stage <- [
          "validate_length(cs, :name, min: 2)",
          "cs |> validate_length(:name, min: 2)",
          "unique_constraint(cs, :email)",
          "cs |> optimistic_lock(:lock_version)"
        ] do
      # The field atom itself never mutates (`validate_length`'s `min:` key still does — it is
      # core's, see below).
      refute Enum.any?(atom_diffs(src(stage), [@atom, @plugin]), fn {original, _} ->
               original in [":name", ":email", ":lock_version"]
             end),
             "expected the field atom held back in `#{stage}`"

      # Control: without the plugin the atom family reaches the field.
      assert Enum.any?(atom_diffs(src(stage), [@atom]), fn {original, _} ->
               original in [":name", ":email", ":lock_version"]
             end),
             "expected the bare atom family to reach the field in `#{stage}`"
    end
  end

  test "a field *list* stays an ordinary expression — core's list families keep reaching it" do
    # The pin is on a written atom only: `validate_required`'s list (and any list-taking stage) is
    # not the plugin's — list mutations are core's, present and future.
    stage = "validate_required(cs, [:name, :email])"

    assert [{":name", ":mutare"}, {":email", ":mutare"}] =
             atom_diffs(src(stage), [@atom, @plugin])

    assert [{_, _} | _] =
             for(
               {:list, original, mutated} <-
                 diffs(src(stage), mutators: [Mutare.Mutators.List, @plugin]),
               do: {original, mutated}
             )
  end

  test "validate_number's option keys are held back while the bound values stay core's" do
    stage = ~s|validate_number(cs, :age, greater_than: 0, message: "small")|

    # No atom mutant at all: the field is pinned and the keys are raw under the per-pair route.
    assert atom_diffs(src(stage), [@atom, @plugin]) == []

    # Control: unrouted, the atom family rewrites the option key into one Ecto raises on.
    assert Enum.any?(atom_diffs(src(stage), [@atom]), fn {original, _} ->
             original == "greater_than:"
           end)

    # The bound literal is still core's off-by-one territory.
    integer =
      for {:integer, original, mutated} <- diffs(src(stage), mutators: [@integer, @plugin]),
          do: {original, mutated}

    assert {"0", "1"} in integer
  end

  test "validate_length's keys stay core's; only a written count: mode is held back" do
    for mode <- [":graphemes", ":codepoints", ":bytes"],
        call <- ["validate_length(cs, :name,", "cs |> validate_length(:name,"] do
      stage = "#{call} min: 2, max: 40, count: #{mode})"

      # Every key reaches core — Ecto ignores an unknown one, so each swap silently drops that
      # option: a live mutant. The field atom and the mode atom do not: `:mutare` is no mode.
      assert atom_diffs(src(stage), [@atom, @plugin]) ==
               [{"min:", "mutare:"}, {"max:", "mutare:"}, {"count:", "mutare:"}]

      # Control: unrouted, the atom family reaches the mode too.
      assert {mode, ":mutare"} in atom_diffs(src(stage), [@atom])

      integer =
        for {:integer, original, _} <- diffs(src(stage), mutators: [@integer, @plugin]),
            do: original

      assert "2" in integer and "40" in integer
    end
  end

  test "computed count modes keep core's comparison and literal mutations" do
    for call <- ["validate_length(cs, :name,", "cs |> validate_length(:name,"] do
      source = """
      defmodule Acct do
        import Ecto.Changeset
        def changeset(cs, mode) do
          #{call} min: 2, count: if(mode == 1, do: :bytes, else: :graphemes))
        end
      end
      """

      core = [Mutare.Mutators.Relational, @integer]
      control = diffs(source, mutators: core)
      routed = diffs(source, mutators: core ++ [@plugin])

      assert {:relational, "mode == 1", "mode != 1"} in control
      assert {:integer, "1", "2"} in control
      assert Enum.reject(routed, fn {family, _, _} -> family == :ecto end) == control
      assert_compiles(source, mutators: core ++ [@plugin])
    end
  end

  test "a mutation inside count changes the selected valid mode" do
    source = """
    defmodule Acct do
      import Ecto.Changeset

      def check(mode) do
        %MyApp.User{}
        |> cast(%{"name" => "é"}, [:name])
        |> validate_length(:name, min: 2, count: if(mode == 1, do: :bytes, else: :graphemes))
      end
    end
    """

    {[mod], sites} =
      Mutare.Test.compile_metamutant(source, [Mutare.Mutators.Relational, @plugin])

    assert {%Ecto.Changeset{valid?: true}, %Ecto.Changeset{valid?: false}} =
             Mutare.Test.observe_mutant(sites, {"mode == 1", "mode != 1"}, fn -> mod.check(1) end)
  end

  test "a swapped validate_length key is a live mutant — that one bound gone, the call intact" do
    source = """
    defmodule Acct do
      import Ecto.Changeset

      def check(name) do
        %MyApp.User{}
        |> cast(%{"name" => name}, [:name])
        |> validate_length(:name, min: 2, max: 40)
      end
    end
    """

    {[mod], sites} = Mutare.Test.compile_metamutant(source, [@atom, @plugin])
    mutant = {"min:", "mutare:"}

    # A one-character name passes once `min:` is unrecognised …
    assert {%Ecto.Changeset{valid?: false}, %Ecto.Changeset{valid?: true}} =
             Mutare.Test.observe_mutant(sites, mutant, fn -> mod.check("a") end)

    # … while the `max:` bound still holds: no crash, and not the whole-call drop either.
    assert {%Ecto.Changeset{valid?: false}, %Ecto.Changeset{valid?: false}} =
             Mutare.Test.observe_mutant(sites, mutant, fn ->
               mod.check(String.duplicate("a", 41))
             end)
  end

  test "an unlisted stage's options stay ordinary expressions" do
    # Only `validate_number` rejects an unknown key; a constraint's `name:` pair — key and value
    # alike — is left to core like `validate_length`'s keys (an unknown key is ignored, so the swap
    # is core's mutant, and an index name is not the plugin's to hold back). The field atom before
    # it is still pinned.
    stage = "unique_constraint(cs, :email, name: :accounts_email_index)"

    assert [{"name:", "mutare:"}, {":accounts_email_index", ":mutare"}] =
             atom_diffs(src(stage), [@atom, @plugin])
  end

  test "a non-atom field slot (prepare_changes' function) is untouched by the pin" do
    stage = "prepare_changes(cs, fn c -> put_change(c, :kind, :x) end)"
    # The pin is positional and shape-gated; the function body's atoms still mutate.
    assert Enum.any?(atom_diffs(src(stage), [@atom, @plugin]), fn {original, _} ->
             original == ":x"
           end)
  end
end
