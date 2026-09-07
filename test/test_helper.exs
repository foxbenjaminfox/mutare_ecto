# The semantic-layer tests bring up their own SQLite-backed `MyApp.Repo` in `setup_all`
# (`Mutare.Ecto.SemanticHarness.start_repo!/0`), so the Repo and the exqlite NIF's runtime cost
# only touch that one file. Every other test run stays DB-free.
# Some fixtures use query API that only newer Ecto has — `identifier/1` and `constant/1`
# arrived in 3.13 — and the CI matrix runs the declared minimum (3.12), where such a fixture
# cannot compile at all. A test that needs them carries `@tag needs_ecto: "~> 3.13"` and is
# excluded below that version; the exclusion shows in the run's summary, so it is never silent.
{:ok, _} = Application.ensure_all_started(:ecto)
ecto_version = to_string(Application.spec(:ecto, :vsn))

unless Version.match?(ecto_version, "~> 3.13"),
  do: ExUnit.configure(exclude: [needs_ecto: "~> 3.13"])

ExUnit.start()
