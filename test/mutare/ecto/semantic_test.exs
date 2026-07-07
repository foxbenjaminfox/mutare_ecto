# The semantic layer of the testing strategy: *does the mutant run?* The unit tests
# (host_test, fragment_test, query_test, …) prove the transform *records* the right Sites and that
# the metamutant *compiles*; these prove a recorded mutant is **live** — that flipping the active id
# changes the SQL the engine runs — by executing real metamutants against a real database.
#
# The whole suite lives in `Mutare.Ecto.SemanticCases` (a `use`-able template) and is instantiated
# once per enabled engine. SQLite is always on (self-contained, the default). Postgres is added when
# `MUTARE_TEST_POSTGRES` is set, as a second module running the identical fixtures against
# `MyApp.PgRepo` and a live server — so a single `mix test` covers one engine or two. Each module is
# `async: false`: they share the process-global `:mutare_active` selection switch, so their tests
# must not interleave.
defmodule Mutare.Ecto.SemanticTest.SQLite do
  use ExUnit.Case, async: false
  use Mutare.Ecto.SemanticCases, repo: MyApp.Repo
end

if Mutare.Ecto.SemanticHarness.postgres_enabled?() do
  defmodule Mutare.Ecto.SemanticTest.Postgres do
    use ExUnit.Case, async: false
    use Mutare.Ecto.SemanticCases, repo: MyApp.PgRepo
  end
end
