defmodule Mutare.Ecto.RootPinDeliveryTest do
  # Sync, though DB-free: the parity test below reads the global active-mutant selector at
  # baseline, which core's flip helpers require `async: false` for (`Mutare.Test`).
  use ExUnit.Case, async: false

  import Mutare.Ecto.TestSupport

  # The root-pin delivery rule (`Mutare.Ecto.Host.Target`): a hosted condition that is itself a
  # `^` pin is woven **pin-only** — `^case … do` over the bare interiors — never behind a
  # `dynamic/2` wrap. Ecto dispatches a root interpolation on its runtime value
  # (`Ecto.Query.Builder.Filter.filter!/6`: a `DynamicExpr`, a boolean, a keyword filter, or an
  # `ArgumentError`), and `dynamic([p], ^value)` would demote all but the first to a parameter.

  # The plugin plus core's builtins — a root pin's mutants are all core's (its SQL catalog is
  # empty), so without them nothing is hosted and there is no delivery to test.
  @with_core [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  # One interior per arm of Ecto's root dispatch, each carrying Elixir that core mutates (so the
  # condition really is hosted) and steered by `f` where the arm depends on a runtime choice.
  @interiors [
    {"a written keyword filter", "[views: 5]"},
    {"a computed keyword filter", "if f, do: [views: 5], else: []"},
    {"a boolean", "f and true"},
    {"a dynamic", "if f, do: dynamic([p], p.views > 1), else: dynamic([p], p.views < 0)"},
    {"neither (Ecto raises)", "if f, do: [views: 5], else: nil"}
  ]

  # Every hosted position a root pin can occupy.
  @positions [
    {"from where:", &__MODULE__.from_where/1},
    {"from having:", &__MODULE__.from_having/1},
    {"from join on:", &__MODULE__.from_on/1},
    {"where/3", &__MODULE__.where_bound/1},
    {"piped where/2", &__MODULE__.where_piped/1},
    {"binding-less where/2", &__MODULE__.where_bare/1},
    {"join on:", &__MODULE__.join_on/1},
    {"unnamed join on:", &__MODULE__.unnamed_join_on/1}
  ]

  def from_where(interior), do: ~s|from(p in "posts", where: ^(#{interior}))|
  def from_having(interior), do: ~s|from(p in "posts", group_by: p.id, having: ^(#{interior}))|
  def from_on(interior), do: ~s|from(c in "c", join: p in "posts", on: ^(#{interior}))|
  def where_bound(interior), do: ~s|where(q, [p], ^(#{interior}))|
  def where_piped(interior), do: ~s|q \|> where([p], ^(#{interior}))|
  def where_bare(interior), do: ~s|where(q, ^(#{interior}))|
  def join_on(interior), do: ~s|join(q, :inner, [c], p in "posts", on: ^(#{interior}))|
  def unnamed_join_on(interior), do: ~s|join(q, :inner, [c], "posts", on: ^(#{interior}))|

  defp module_source(body) do
    """
    defmodule M do
      import Ecto.Query

      def run(q, f) do
        _ = {q, f}
        #{body}
      end
    end
    """
  end

  # What building the query yields: its logical rendering (Ecto's `Inspect` — file/line-free,
  # and it spells a keyword filter `p0.views == ^5` but a demoted one `^[views: 5]`), or the
  # exception it raises.
  defp outcome(build) do
    {:ok, inspect(build.())}
  rescue
    error -> {:raised, error.__struct__, Exception.message(error)}
  end

  test "instrumenting a root pin leaves the baseline query exactly as Ecto builds it uninstrumented" do
    import Ecto.Query, only: [from: 1]
    base = from(c in "c")

    for {position, body_for} <- @positions, {arm, interior} <- @interiors do
      body = body_for.(interior)
      source = module_source(body)

      # Not vacuous: the pin really is woven.
      assert metamutant(source, @with_core) =~ "^case",
             "expected the root pin in `#{body}` to be hosted"

      {plain, _binding} =
        Code.eval_string("import Ecto.Query\nfn q, f -> _ = {q, f}; #{body} end")

      {[instrumented], _sites} = Mutare.Test.compile_metamutant(source, mutators(@with_core))

      for f <- [true, false] do
        expected = outcome(fn -> plain.(base, f) end)

        actual =
          Mutare.Test.with_active_mutant(0, fn ->
            outcome(fn -> instrumented.run(base, f) end)
          end)

        assert actual == expected,
               "#{position}, #{arm}, f = #{f}: the woven baseline diverged from Ecto's own\n" <>
                 "  uninstrumented: #{inspect(expected)}\n" <>
                 "  instrumented:   #{inspect(actual)}"
      end
    end
  end

  test "a root keyword filter's value mutant is a live native filter, not a parameter" do
    import Ecto.Query, only: [from: 1]

    source = module_source(~s|where(q, ^[views: 5])|)
    {[instrumented], sites} = Mutare.Test.compile_metamutant(source, mutators(@with_core))

    {baseline, mutant} =
      Mutare.Test.observe_mutant(sites, {"^[views: 5]", "^[views: 6]"}, fn ->
        inspect(instrumented.run(from(c in "c"), true))
      end)

    assert baseline =~ "where: c0.views == ^5"
    assert mutant =~ "where: c0.views == ^6"
  end

  test "the weave is pin-only: bare interiors as branches, and the recorded diff keeps its pin" do
    source = module_source(~s|where(q, ^[views: 5])|)
    woven = metamutant(source, @with_core)

    assert woven =~ "^case"
    refute woven =~ "dynamic", "a root pin must not be wrapped in `dynamic/2`:\n#{woven}"

    # The logical fragment is still the written condition, `^` included — only delivery unpins.
    assert {:integer, "^[views: 5]", "^[views: 6]"} in diffs(source, @with_core)
  end

  test "a pin *inside* a predicate still rides the dynamic wrap" do
    # The other half of the rule: nested under a predicate, `^` is a parameter both natively and
    # inside `dynamic/2`, so the ordinary wrap is behaviour-preserving and stays.
    source = module_source(~s|where(q, [p], p.views > ^(2 + 3))|)
    assert metamutant(source, @with_core) =~ "Ecto.Query.dynamic([p], p.views > ^(2 + 4))"
  end

  test "an unnamed standalone join's root-pin on: weaves pin-only — an inline dynamic mutates" do
    # The plugin alone: an inline `dynamic` in the pin is the plugin's own to mutate, whole-call.
    source =
      module_source(~s|join(q, :inner, [p], subquery(q), on: ^dynamic([p, s], s.id > p.id))|)

    assert {"^dynamic([p, s], s.id > p.id)", "^dynamic([p, s], s.id >= p.id)"} in ecto_diffs(
             source
           )

    woven = metamutant(source)
    assert woven =~ "^case"
    refute woven =~ "Elixir.Ecto.Query.dynamic", "pin-only: no woven wrap, no bindings\n#{woven}"
    assert_compiles(source)
  end

  test "a root pin lowered out of an outer pin's interior is rebuilt natively too" do
    # An inner query built inside a pin cannot nest a weave, so core lowers its hosted target to
    # a whole-call rebuild — `splice.(call, wrap.(mutant))`, the same `wrap`. The lowered mutant
    # must therefore be the native `where: ^[views: 6]`, not `where: ^dynamic(…, ^[views: 6])`.
    source =
      module_source(
        ~s|where(q, [u], u.id in ^f.all(from(p in "posts", where: ^[views: 5], select: p.id)))|
      )

    lowered = for {:integer, _original, mutated} <- diffs(source, @with_core), do: mutated

    assert Enum.any?(lowered, &(&1 =~ ~s|from(p in "posts", where: ^[views: 6], select: p.id)|)),
           "expected a natively rebuilt inner filter among:\n#{Enum.join(lowered, "\n")}"

    refute Enum.any?(lowered, &(&1 =~ ~r/dynamic\([^)]*\^\[views/))
  end
end
