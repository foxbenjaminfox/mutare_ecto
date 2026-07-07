defmodule Mutare.Ecto.SemanticHarness do
  @moduledoc false
  # The semantic-layer test harness — *does the mutant run?* Where the unit tests assert *what*
  # the transform records (Sites, rendered scaffolding),
  # this proves the recorded mutant is **live**: it takes a real metamutant, compiles it, flips the
  # `:persistent_term` active-id switch the metamutant reads, and runs the resulting query against
  # a real Repo — confirming the injected `^`/`dynamic` fragment actually changed the SQL the engine
  # ran, not just the source on disk.
  #
  # Every DB-touching helper takes the **Repo module** as its first argument, because the semantic
  # suite runs the same fixtures against one or two engines: always `MyApp.Repo` (SQLite), and —
  # when `postgres_enabled?/0` — also `MyApp.PgRepo` (Postgres), as a second generated test module.
  # The engine follows the repo (`repo.__adapter__()`); nothing here reads a global "which DB" flag
  # beyond `postgres_enabled?/0`, which only gates *whether* the Postgres module is defined.
  #
  # The flow mirrors a real `mix mutare` run end to end:
  #
  #   1. `Mutare.transform_string/2` rewrites the source into the metamutant (every mutant behind the
  #      `case :persistent_term.get(:mutare_active, 0)` selector), returning the `Mutare.Site`s.
  #   2. `Code.compile_string/1` compiles that metamutant into a live module (the single build).
  #   3. `under/3` sets `:mutare_active` to a chosen mutant id and builds + runs the query — exactly
  #      what Mutare's runner does per mutant, minus the suite.
  #
  # Baseline is id `0` (the selector's default), so `under(repo, 0, …)` runs the *original* query and
  # `under(repo, id, …)` the mutant; a semantic test asserts the two result sets differ in the
  # SQL-meaningful way the mutation predicts.

  alias Mutare.Ecto.TestSupport
  alias Mutare.{Site, Test}

  @doc """
  Whether the Postgres engine is enabled for this run (`MUTARE_TEST_POSTGRES` truthy).

  Read at the semantic test's compile time to decide whether to generate the second (Postgres) test
  module. Test `.exs` files recompile on every `mix test`, so flipping the var takes effect
  immediately — no forced rebuild. Off by default: the suite runs SQLite-only unless asked.
  """
  @spec postgres_enabled?() :: boolean()
  def postgres_enabled? do
    String.downcase(System.get_env("MUTARE_TEST_POSTGRES", "")) in ["1", "true", "yes", "on"]
  end

  @doc """
  Bring up `repo` for the semantic suite and seed the read-only fixtures.

  Call once from a semantic test module's `setup_all` (not `test_helper.exs`): the DB is only needed
  by the semantic modules, so booting it here keeps every other test run — and the driver NIF's
  runtime cost — out of it. `start_supervised!/1` ties the Repo to ExUnit's supervisor, so it lives
  exactly as long as the module's tests and stops cleanly afterward; `on_exit/1` then restores the
  `Application` env this set (and, on SQLite, removes the temp files), leaving no VM state behind.
  The process-global selection switch needs no cleanup of its own: `under/3` runs every activation
  through `Mutare.Test.with_active_mutant/2`, which restores the prior active id in an `after` block,
  so no test leaks one (and the at-most residual value is baseline `0`, i.e. unset).

  The **engine follows `repo.__adapter__()`**: a SQLite repo stands up a fresh temp file, a Postgres
  repo connects to a running server. Either way seeding is `MyApp.Seed.populate!/1`, which reads the
  same adapter to emit portable DDL.
  """
  @spec start_repo!(module()) :: :ok
  def start_repo!(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> start_postgres!(repo)
      _sqlite -> start_sqlite!(repo)
    end
  end

  # SQLite: a fresh temp file *carrying the OS pid*, so two concurrent `mix test` runs on one host
  # get independent files instead of clobbering a shared one (`pool_size: 1` + `async: false` means a
  # single connection owns the seeded rows within a run). Stale files from a crashed prior run with
  # the same pid are removed on the way in and on the way out.
  @spec start_sqlite!(module()) :: :ok
  defp start_sqlite!(repo) do
    db_path = Path.join(System.tmp_dir!(), "mutare_ecto_semantic_#{System.pid()}.db")
    db_files = [db_path, db_path <> "-wal", db_path <> "-shm"]
    Enum.each(db_files, &File.rm/1)

    boot!(
      repo,
      [
        database: db_path,
        pool_size: 1,
        journal_mode: :wal,
        log: false,
        stacktrace: true
      ],
      fn -> Enum.each(db_files, &File.rm/1) end
    )
  end

  # Postgres: connect to a running server, configured from the standard `PG*` env vars (with local
  # defaults). Unlike SQLite there is no per-run file to isolate; the seeded rows are committed and
  # visible to every connection, so the pool size is a robustness knob, not a correctness one. Under
  # a full `mix test` the semantic module boots *while* dozens of CPU-heavy async tests run, and a
  # single Postgres connection's TCP+auth handshake can lose the scheduler long enough to blow the
  # default checkout timeout (SQLite has no handshake, so it never hits this). A small pool plus
  # generous queue/checkout timeouts absorb that startup contention. `storage_up/1` is best-effort so
  # a locally-missing database is created on the fly, while in CI the service has already provisioned
  # it (an `:already_up` is expected and ignored). Table (re)creation is `MyApp.Seed.populate!/1`'s job.
  @spec start_postgres!(module()) :: :ok
  defp start_postgres!(repo) do
    config = [
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      database: System.get_env("PGDATABASE", "mutare_ecto_test"),
      pool_size: 2,
      queue_target: 1_000,
      queue_interval: 5_000,
      timeout: 15_000,
      log: false,
      stacktrace: true
    ]

    _ = repo.__adapter__().storage_up(config)
    boot!(repo, config, fn -> :ok end)
  end

  # Shared boot: install `config`, start + seed `repo`, and register teardown that restores the prior
  # `Application` env exactly (capturing it *before* the `put_env` mutates process-global state) and
  # runs `cleanup` (engine-specific file removal, or a no-op).
  @spec boot!(module(), keyword(), (-> any())) :: :ok
  defp boot!(repo, config, cleanup) do
    prior_env = Application.fetch_env(:mutare_ecto, repo)
    Application.put_env(:mutare_ecto, repo, config)

    ExUnit.Callbacks.start_supervised!(repo)
    MyApp.Seed.populate!(repo)

    ExUnit.Callbacks.on_exit(fn ->
      case prior_env do
        {:ok, value} -> Application.put_env(:mutare_ecto, repo, value)
        :error -> Application.delete_env(:mutare_ecto, repo)
      end

      cleanup.()
    end)

    :ok
  end

  @doc """
  Whether `repo`'s engine can execute a `FULL JOIN` — for gating the full-join liveness fixture.

  Postgres always can; SQLite only at 3.39+. Runtime-guarded (not tag-skipped) because the engine
  version is a property of the running matrix entry, not of the mutation being delivered.
  """
  @spec full_join_supported?(module()) :: boolean()
  def full_join_supported?(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> true
      _sqlite -> sqlite_version(repo) >= {3, 39}
    end
  end

  # The running SQLite's `{major, minor}` version tuple.
  @spec sqlite_version(module()) :: {integer(), integer()}
  defp sqlite_version(repo) do
    %{rows: [[version]]} = Ecto.Adapters.SQL.query!(repo, "select sqlite_version()", [])

    version
    |> String.split(".")
    |> Enum.take(2)
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  @doc """
  Render `source` to its metamutant, compile it, and return `{module, sites}`.

  A thin wrapper over `Mutare.Test.compile_metamutant/3`: it threads the plugin's mutators
  (`TestSupport.mutators/1`, defaulting the plugin's `repo:` to `opts[:repo]`) and unwraps the single
  fixture module. Core compiles the rendered metamutant — selector `case`s, woven `dynamic`s,
  coverage catch-all and all — inside a uniquely-named wrapper module (so two fixtures named
  `defmodule Q` never clash through the global `Code.compile_string`), and purges every compiled
  module on test exit. `sites` are the `Mutare.Site`s, used to look up a mutant's id by its logical
  diff (`site_id/2`). Pass `repo:` (and any `mutators:`) through `opts`.
  """
  @spec compile(String.t(), keyword()) :: {module(), [Site.t()]}
  def compile(source, opts \\ []) do
    {[module], sites} = Test.compile_metamutant(source, TestSupport.mutators(opts))
    {module, sites}
  end

  @doc """
  Run `fun` under active mutant `id` and return its result verbatim.

  Sets the selection switch via `Mutare.Test.with_active_mutant/2` — which routes through
  `Mutare.Selector` (so it never hardcodes the key) and restores the prior active id afterwards, so
  one test can't leak an active id into the next — for the duration of `fun`. This is the
  write-path runner: an `:on_conflict` mutant changes what `Repo.insert/2` *does* (overwrite vs skip
  vs raise) rather than which rows a query returns, so the fixture performs the effect (calling its
  own baked-in repo) and the test observes the table directly. `under/3` builds the query-path
  observation on top of it — hence this one takes no repo.
  """
  @spec activate(non_neg_integer(), (-> result)) :: result when result: term()
  def activate(id, fun) when is_integer(id) and id >= 0 do
    Test.with_active_mutant(id, fun)
  end

  @doc """
  Run `fun` under active mutant `id` and return `repo.all/1` of the query it builds.

  The query-path observation: `fun` builds and returns an `Ecto.Queryable` (typically
  `fn -> module.some_query() end`), which is run against the seeded `repo` under the chosen mutant
  id. Prefer `observe/4` when the test is the standard flip-and-compare pair; `under/3` remains for a
  mutant located by an ad-hoc `site_by/3` predicate (the drops) or observed more than once.
  """
  @spec under(module(), non_neg_integer(), (-> Ecto.Queryable.t())) :: [term()]
  def under(repo, id, fun) when is_integer(id) and id >= 0 do
    activate(id, fn -> repo.all(fun.()) end)
  end

  @doc """
  The flip-and-compare pair for the query path: run `fun`'s query at baseline and under the one
  site matching `pattern`, returning `{baseline_rows, mutant_rows}`.

  Composes core's `Mutare.Test.observe_mutant/3` — which resolves the mutant id (`site_id/2`) and
  runs the baseline **first, pinned to core's baseline selection** (not the current one), so a
  leaked active id can't masquerade as baseline and a wrong first element indicts the fixture,
  not the mutant — with the harness's Repo observation (`repo.all/1` of the queryable `fun`
  builds). `sites` and `pattern` are as in `Mutare.Test.site_id/2`.
  """
  @spec observe(module(), [Site.t()], {pattern, pattern}, (-> Ecto.Queryable.t())) ::
          {[term()], [term()]}
        when pattern: String.t() | Regex.t()
  def observe(repo, sites, pattern, fun) do
    Test.observe_mutant(sites, pattern, fn -> repo.all(fun.()) end)
  end
end
