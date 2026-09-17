defmodule Mutare.Ecto.ValidationBoundaryTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # `Mutare.Ecto.ValidationBoundary`: the strict/non-strict swap of a `validate_number/3` bound —
  # `greater_than` ↔ `greater_than_or_equal_to`, `less_than` ↔ `less_than_or_equal_to` — delivered in
  # place, one mutant per swappable option, tagged with the written key.

  defp changeset_src(stage) do
    """
    defmodule Acct do
      import Ecto.Changeset
      def changeset(cs), do: cs |> #{stage}
    end
    """
  end

  # The `:validation_boundary` diffs only — the same fixture also records a `:validation_drop`.
  defp boundary_diffs(src, opts \\ []) do
    src
    |> sites(opts)
    |> Enum.filter(&(&1.mutator == :ecto and "validation_boundary" in &1.variant))
    |> Enum.map(&{&1.original_code, &1.mutated_code})
  end

  describe "the four swaps" do
    test "each strict bound swaps to its non-strict twin and back, in the piped form" do
      for {written, twin} <- [
            {"greater_than", "greater_than_or_equal_to"},
            {"greater_than_or_equal_to", "greater_than"},
            {"less_than", "less_than_or_equal_to"},
            {"less_than_or_equal_to", "less_than"}
          ] do
        src = changeset_src("validate_number(:age, #{written}: 18)")

        assert boundary_diffs(src) == [{"#{written}:", "#{twin}:"}],
               "expected the #{written} → #{twin} swap"
      end
    end

    test "the direct form rebuilds the whole call with the changeset argument kept" do
      src = """
      defmodule Acct do
        import Ecto.Changeset
        def changeset(cs), do: validate_number(cs, :age, less_than: 100)
      end
      """

      assert boundary_diffs(src) == [{"less_than:", "less_than_or_equal_to:"}]

      assert metamutant(src) =~ "validate_number(cs, :age, less_than_or_equal_to: 100)"
      assert_compiles(src)
    end

    test "a qualified and an aliased spelling resolve like the imported one" do
      for call <- [
            "Ecto.Changeset.validate_number(cs, :age, greater_than: 0)",
            "cs |> Changeset.validate_number(:age, greater_than: 0)"
          ] do
        src = """
        defmodule Acct do
          alias Ecto.Changeset
          def changeset(cs), do: #{call}
        end
        """

        assert boundary_diffs(src) == [{"greater_than:", "greater_than_or_equal_to:"}]
        assert_compiles(src)
      end
    end
  end

  describe "what stays as written" do
    test "two bounds on one call swap independently, each keeping the other" do
      src = changeset_src("validate_number(:age, greater_than: 0, less_than: 150)")

      assert boundary_diffs(src) == [
               {"greater_than:", "greater_than_or_equal_to:"},
               {"less_than:", "less_than_or_equal_to:"}
             ]

      rendered = metamutant(src)
      assert rendered =~ "validate_number(:age, greater_than_or_equal_to: 0, less_than: 150)"
      assert rendered =~ "validate_number(:age, greater_than: 0, less_than_or_equal_to: 150)"
    end

    test "equal_to / not_equal_to and message: are never swapped" do
      # The moduledoc's exclusions: a polarity flip of `equal_to` is killed by any happy-path
      # test (no signal beyond the whole-call drop), and `message:` is not a bound.
      src = changeset_src(~s|validate_number(:age, equal_to: 1, not_equal_to: 2, message: "no")|)
      assert boundary_diffs(src) == []
    end

    test "a non-keyword options argument yields nothing — no written key to swap" do
      src = """
      defmodule Acct do
        import Ecto.Changeset
        def changeset(cs, opts), do: validate_number(cs, :age, opts)
      end
      """

      assert boundary_diffs(src) == []
    end

    test "validate_length's inclusive min/max have no strict twin" do
      src = changeset_src("validate_length(:name, min: 2, max: 40)")
      assert boundary_diffs(src) == []
    end
  end

  describe "tags, filter, and note" do
    test "a directive beside a multiline bound suppresses only that option's swap" do
      for call <- ["validate_number(cs, :age,", "cs |> validate_number(:age,"],
          label <- ["greater_than", "validation_boundary"] do
        src = """
        defmodule Acct do
          import Ecto.Changeset
          def changeset(cs) do
            #{call}
              greater_than: 0, # mutare:ignore[ecto:#{label}]
              less_than: 150
            )
          end
        end
        """

        bounds = src |> sites() |> Enum.filter(&("validation_boundary" in &1.variant))
        assert [lower, upper] = bounds
        assert lower.line == 5
        assert upper.line == 6
        assert lower.ignored
        refute upper.ignored

        assert {lower.original_code, lower.mutated_code} ==
                 {"greater_than:", "greater_than_or_equal_to:"}

        assert_compiles(src)
      end
    end

    test "the mutant is tagged with its family and the written key, so either label suppresses it" do
      src = changeset_src("validate_number(:age, greater_than: 0)")
      [site] = src |> sites() |> Enum.filter(&("validation_boundary" in &1.variant))
      assert site.variant == ["validation_boundary", "greater_than"]

      # A directive marks the site `ignored` (core keeps it in the record).
      for label <- ["validation_boundary", "greater_than"] do
        suppressed =
          changeset_src("validate_number(:age, greater_than: 0) # mutare:ignore[ecto:#{label}]")

        [site] = suppressed |> sites() |> Enum.filter(&("validation_boundary" in &1.variant))
        assert site.ignored, "expected #{label} to suppress the swap"
      end

      # The sibling label leaves it running.
      other =
        changeset_src("validate_number(:age, greater_than: 0) # mutare:ignore[ecto:less_than]")

      [site] = other |> sites() |> Enum.filter(&("validation_boundary" in &1.variant))
      refute site.ignored
    end

    test "the family is default-on and independently toggleable" do
      src = changeset_src("validate_number(:age, greater_than: 0)")
      assert length(boundary_diffs(src)) == 1

      assert boundary_diffs(src,
               mutators: [{Mutare.Ecto, families: {:default, except: [:validation_boundary]}}]
             ) == []

      assert [_only] =
               boundary_diffs(src, mutators: [{Mutare.Ecto, families: [:validation_boundary]}])
    end

    test "the mutant carries the boundary equivalence note" do
      src = changeset_src("validate_number(:age, greater_than: 0)")
      [site] = src |> sites() |> Enum.filter(&("validation_boundary" in &1.variant))

      assert site.note ==
               "kill may require a changeset whose value sits exactly on the bound — strict and non-strict number validations (greater_than vs greater_than_or_equal_to, less_than vs less_than_or_equal_to) accept the same values except one equal to the bound"

      assert :validation_boundary in Mutare.Ecto.equivalence_sensitive_families()
    end
  end
end

defmodule Mutare.Ecto.ValidationBoundaryTest.Runtime do
  # Sync: this module runs a metamutant, and the selector it flips is global
  # (`Mutare.Ecto.SelectorSyncTest`).
  use ExUnit.Case, async: false

  import Mutare.Ecto.TestSupport

  describe "liveness" do
    test "a value exactly on the bound flips the verdict under the mutant" do
      # The mutant is observable without a Repo: `apply_action/2` runs the validations. A
      # changeset with `age: 0` fails `greater_than: 0` and passes `greater_than_or_equal_to: 0`,
      # so the flip-and-compare shows the baseline invalid and the mutant valid.
      src = """
      defmodule Acct do
        import Ecto.Changeset

        def check(age) do
          %MyApp.User{}
          |> cast(%{"age" => age}, [:age])
          |> validate_number(:age, greater_than: 0)
          |> apply_action(:insert)
        end
      end
      """

      {[mod], sites} = Mutare.Test.compile_metamutant(src, mutators([]))
      pattern = {"greater_than:", "greater_than_or_equal_to:"}

      assert {{:error, %Ecto.Changeset{valid?: false}}, {:ok, %MyApp.User{age: 0}}} =
               Mutare.Test.observe_mutant(sites, pattern, fn -> mod.check(0) end)

      # Off the bound the two agree — the equivalence note's reason, observed.
      assert {{:ok, _}, {:ok, _}} =
               Mutare.Test.observe_mutant(sites, pattern, fn -> mod.check(1) end)
    end
  end
end
