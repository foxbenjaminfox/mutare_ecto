defmodule Mutare.Ecto.TestSupport do
  @moduledoc false
  # Shared helpers layered on `Mutare.Test` — core's public test surface for custom-mutator
  # projects. They thread the plugin's default configuration (the `{Mutare.Ecto, repo: …}`
  # mutator and the `:all` shorthand) into core's `diffs`/`diffs_for`/`assert_metamutant_compiles`,
  # and add a `metamutant/1` that returns the rendered source — for the `=~` scaffolding checks
  # (`dynamic([u], …)`) the `Mutare.Test` helpers don't cover.
  #
  # `expand_uses: true` is the transform default, so the `Mutare.Test` helpers (which don't pass
  # it) still get the `use Ecto.Schema` / `use MyAppWeb` expansion the schema/query routing needs.

  @repo MyApp.Repo

  @doc "Every recorded `{mutator, original_code, mutated_code}` for `source` (all families)."
  def diffs(source, opts \\ []), do: Mutare.Test.diffs(source, mutators(opts))

  @doc "The `{original_code, mutated_code}` pairs the `:ecto` family records for `source`."
  def ecto_diffs(source, opts \\ []), do: Mutare.Test.diffs_for(source, mutators(opts), :ecto)

  @doc """
  Assert the metamutant embedding every mutant of `source` compiles (the single-build net).

  The top-level module name is made unique per call first: `assert_metamutant_compiles`
  compiles through the global `Code.compile_string`, so two `async: true` tests that both
  define, say, `defmodule Posts` would race the compiler ("cannot compile module Posts") —
  the module name is irrelevant to what we assert, so we sidestep the clash entirely.
  """
  def assert_compiles(source, opts \\ []),
    do: source |> uniquify_module() |> Mutare.Test.assert_metamutant_compiles(mutators(opts))

  @doc "The rendered metamutant source for `source` — for `=~` checks on the woven scaffolding."
  def metamutant(source, opts \\ []) do
    {metamutant, _sites, _next_id} =
      Mutare.transform_string(source, mutators: mutators(opts), expand_uses: true)

    metamutant
  end

  @doc """
  Append a per-call unique suffix to the source's top-level module name.

  Both `assert_compiles/2` and the semantic harness compile through the global
  `Code.compile_string`, so two tests that both define, say, `defmodule Posts` would otherwise race
  the compiler ("cannot compile module Posts"). Only the first `defmodule <Name>` is rewritten; the
  query schema/Repo aliases the body references are untouched (they are external, not the unit under
  compilation).
  """
  def uniquify_module(source) do
    suffix = System.unique_integer([:positive])
    # `\g{1}` (not `\1`) delimits the backreference so the trailing suffix digits aren't read
    # as part of the group number.
    String.replace(source, ~r/defmodule\s+([\w.]+)/, "defmodule \\g{1}#{suffix}", global: false)
  end

  @doc """
  The `:mutators` list, expanding the `:all` shorthand and defaulting to the Ecto plugin alone.

  Defaulting to `[{Mutare.Ecto, repo: MyApp.Repo}]` keeps recorded mutations exactly the plugin's,
  with nothing from core's built-ins.
  """
  def mutators(opts) do
    opts
    |> Keyword.get(:mutators, [{Mutare.Ecto, repo: @repo}])
    |> Enum.flat_map(fn
      :all -> Mutare.Mutators.all()
      other -> [other]
    end)
  end
end
