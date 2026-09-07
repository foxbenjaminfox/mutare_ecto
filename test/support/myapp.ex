defmodule MyApp.Repo do
  @moduledoc false
  # A *real* Repo for the semantic-layer tests (`test/mutare/ecto/semantic_test.exs`). `MyApp.Repo`
  # is the module name every other test already uses as a bare symbol inside the source strings it
  # transforms (`{Mutare.Ecto, repo: MyApp.Repo}`); making it an actual Repo here lets the semantic
  # tests run the metamutant queries those strings produce against a live SQL engine — proving the
  # woven `^`/`dynamic` mutants change real result sets, not just that the rewrite compiles. Started
  # + seeded once per test module by `Mutare.Ecto.SemanticHarness.start_repo!/1` from the semantic
  # suite's `setup_all` (not `test_helper.exs` — every other test run stays DB-free).
  #
  # This is the **default** (SQLite via `ecto_sqlite3`): self-contained, no server. Its Postgres twin
  # `MyApp.PgRepo` is defined below. Both are compiled unconditionally — an Ecto repo bakes its
  # adapter in at compile time, so running the same fixtures against two engines needs two modules —
  # and the semantic suite generates one test module per enabled engine, each pointed at the matching
  # repo. `MyApp.Seed` reads `repo.__adapter__()` to emit the right per-engine column types.
  use Ecto.Repo, otp_app: :mutare_ecto, adapter: Ecto.Adapters.SQLite3
end

defmodule MyApp.PgRepo do
  @moduledoc false
  # The Postgres twin of `MyApp.Repo` (via `postgrex`), used by the semantic suite's Postgres test
  # module when Postgres is enabled (`MUTARE_TEST_POSTGRES`; see `Mutare.Ecto.SemanticHarness`). It
  # shares `MyApp`'s adapter-agnostic schemas — only the Repo carries an adapter, and the harness
  # supplies a running server's connection config at `start_repo!/1`. Compiling it needs no server;
  # it stays inert (never started) unless the Postgres module is generated.
  use Ecto.Repo, otp_app: :mutare_ecto, adapter: Ecto.Adapters.Postgres
end
