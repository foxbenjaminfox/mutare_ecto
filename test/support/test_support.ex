defmodule Mutare.Ecto.TestSupport do
  @moduledoc false
  # Shared helpers layered on `Mutare.Test` — core's public test surface for custom-mutator
  # projects. Each is a thin thread of the plugin's default configuration (the
  # `{Mutare.Ecto, repo: …}` mutator and the `:all` shorthand) into the core helper of the same
  # shape (`diffs`/`diffs_for`/`assert_metamutant_compiles`/`metamutant_source`); every remaining
  # option (`:extensions`, `:macro_routes`, `expand_uses: false`, …) is forwarded to
  # `Mutare.transform_string/2` through the core helpers' trailing `opts`.
  #
  # `expand_uses: true` is the transform default the source helpers inherit — the
  # `use Ecto.Schema` / `use MyAppWeb` expansion the schema/query routing needs.

  @repo MyApp.Repo

  @doc "Every recorded `{mutator, original_code, mutated_code}` for `source` (all families)."
  def diffs(source, opts \\ []),
    do: Mutare.Test.diffs(source, mutators(opts), transform_opts(opts))

  @doc "The `{original_code, mutated_code}` pairs the `:ecto` family records for `source`."
  def ecto_diffs(source, opts \\ []),
    do: Mutare.Test.diffs_for(source, mutators(opts), :ecto, transform_opts(opts))

  @doc """
  Assert the metamutant embedding every mutant of `source` compiles (the single-build net).

  Delegates straight to `Mutare.Test.assert_metamutant_compiles/3`, which compiles the metamutant
  inside a uniquely-named wrapper module — so two `async: true` tests that both define, say,
  `defmodule Posts` can't race the global compiler ("cannot compile module Posts"), with no source
  rewriting on our side.
  """
  def assert_compiles(source, opts \\ []),
    do: Mutare.Test.assert_metamutant_compiles(source, mutators(opts), transform_opts(opts))

  @doc "The rendered metamutant source for `source` — for `=~` checks on the woven scaffolding."
  def metamutant(source, opts \\ []),
    do: Mutare.Test.metamutant_source(source, mutators(opts), transform_opts(opts))

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

  # Everything except `:mutators` (consumed by `mutators/1` above) rides through to
  # `Mutare.transform_string/2` via the core helpers' trailing `opts`.
  defp transform_opts(opts), do: Keyword.delete(opts, :mutators)
end
