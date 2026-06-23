defmodule Mutare.Ecto.TestSupport do
  @moduledoc false
  # Shared helpers for the plugin's unit tests: run `Mutare.transform_string/2` with only the
  # Ecto mutator enabled (so the recorded sites are exactly the plugin's, nothing from core's
  # built-ins) and a stand-in Repo. `expand_uses: true` is the default, but explicit here since
  # the schema/query routing depends on it.

  @repo MyApp.Repo

  @doc "The `[%Mutare.Site{}]` the Ecto mutator records for `source`."
  def sites(source, opts \\ []) do
    {_metamutant, sites, _next_id} = run(source, opts)
    sites
  end

  @doc "The rendered metamutant source for `source` (for compile-safety checks)."
  def metamutant(source, opts \\ []) do
    {metamutant, _sites, _next_id} = run(source, opts)
    metamutant
  end

  defp run(source, opts) do
    mutators =
      opts
      |> Keyword.get(:mutators, [{Mutare.Ecto, repo: @repo}])
      |> Enum.flat_map(fn
        :all -> Mutare.Mutators.all()
        other -> [other]
      end)

    Mutare.transform_string(source, mutators: mutators, expand_uses: true)
  end
end
