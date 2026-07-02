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

  Delegates straight to `Mutare.Test.assert_metamutant_compiles/2`, which compiles the metamutant
  inside a uniquely-named wrapper module — so two `async: true` tests that both define, say,
  `defmodule Posts` can't race the global compiler ("cannot compile module Posts"), with no source
  rewriting on our side.
  """
  def assert_compiles(source, opts \\ []),
    do: Mutare.Test.assert_metamutant_compiles(source, mutators(opts))

  @doc "The rendered metamutant source for `source` — for `=~` checks on the woven scaffolding."
  def metamutant(source, opts \\ []) do
    %Mutare.Transform.Result{metamutant: metamutant} =
      Mutare.transform_string(source, mutators: mutators(opts), expand_uses: true)

    metamutant
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
