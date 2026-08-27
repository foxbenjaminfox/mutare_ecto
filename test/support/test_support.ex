defmodule Mutare.Ecto.TestSupport do
  @moduledoc false
  # Shared helpers layered on `Mutare.Test` — core's public test surface for custom-mutator
  # projects. Each is a thin thread of the plugin's default configuration (the
  # `{Mutare.Ecto, repo: …}` mutator and the `:all` shorthand) into the core helper of the same
  # shape (`diffs`/`diffs_for`/`assert_metamutant_compiles`/`metamutant_source`) — except `sites`,
  # which has no core counterpart (the `diffs` projections drop the Site) and reads
  # `Mutare.transform_string/2`'s result directly. Every remaining option (`:extensions`,
  # `:macro_routes`, `:file`, `expand_uses: false`, …) is forwarded to `Mutare.transform_string/2`
  # through the trailing `opts`.
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
  Every `Mutare.Transform.Site` recorded for `source` — the transform result itself.

  For assertions on a Site's own fields (`variant`, `note`, `line`, `mutator`, `ignored`, …) that
  the `diffs` projections drop; `# mutare:ignore` directives are resolved, as in a real run. `opts`
  are threaded as in `diffs/2`.
  """
  def sites(source, opts \\ []) do
    %Mutare.Transform.Result{mutants: sites} =
      Mutare.transform_string(
        source,
        Keyword.put(transform_opts(opts), :mutators, mutators(opts))
      )

    sites
  end

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

  Defaulting to `[{Mutare.Ecto, repo: repo}]` — where `repo` is `opts[:repo]` or `MyApp.Repo` —
  keeps recorded mutations exactly the plugin's, with nothing from core's built-ins. The semantic
  suite passes `repo:` so a Postgres run points the plugin at `MyApp.PgRepo`; unit tests omit it and
  get the default.
  """
  def mutators(opts) do
    repo = Keyword.get(opts, :repo, @repo)

    opts
    |> Keyword.get(:mutators, [{Mutare.Ecto, repo: repo}])
    |> Enum.flat_map(fn
      :all -> Mutare.Mutators.all()
      other -> [other]
    end)
  end

  # Everything except `:mutators`/`:repo` (consumed by `mutators/1` above) rides through to
  # `Mutare.transform_string/2` via the core helpers' trailing `opts`.
  defp transform_opts(opts), do: Keyword.drop(opts, [:mutators, :repo])
end
