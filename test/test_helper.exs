# The semantic-layer tests bring up their own SQLite-backed `MyApp.Repo` in `setup_all`
# (`Mutare.Ecto.SemanticHarness.start_repo!/0`), so the Repo and the exqlite NIF's runtime cost
# only touch that one file. Every other test run stays DB-free.
# Some fixtures need a newer Ecto than the declared minimum (3.12.0) the CI matrix runs:
# `identifier/1` and `constant/1` arrived in 3.13, and before 3.12.5 the planner crashes on a
# `parent_as` in a subquery's `select`. A test that needs one carries `@tag needs_ecto: <requirement>`
# and is excluded where the running Ecto misses it; the exclusion shows in the run's summary, so it
# is never silent. Each requirement a tag uses must be listed below.
{:ok, _} = Application.ensure_all_started(:ecto)
ecto_version = to_string(Application.spec(:ecto, :vsn))

unmet =
  for requirement <- ["~> 3.13", ">= 3.12.5"],
      not Version.match?(ecto_version, requirement),
      do: {:needs_ecto, requirement}

ExUnit.configure(exclude: unmet)

ExUnit.start()
