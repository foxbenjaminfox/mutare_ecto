defmodule Mutare.Ecto.SemanticHarness do
  @moduledoc false
  # The semantic-layer test harness (`DESIGN.md`, "Testing strategy" → *Semantic (does the mutant
  # run)*). Where the unit tests assert *what* the transform records (Sites, rendered scaffolding),
  # this proves the recorded mutant is **live**: it takes a real metamutant, compiles it, flips the
  # `:persistent_term` active-id switch the metamutant reads, and runs the resulting query against
  # the real `MyApp.Repo` — confirming the injected `^`/`dynamic` fragment actually changed the SQL
  # the engine ran, not just the source on disk.
  #
  # The flow mirrors a real `mix mutare` run end to end:
  #
  #   1. `Mutare.transform_string/2` rewrites the source into the metamutant (every mutant behind the
  #      `case :persistent_term.get(:mutare_active, 0)` selector), returning the `Mutare.Site`s.
  #   2. `Code.compile_string/1` compiles that metamutant into a live module (the single build).
  #   3. `under/2` sets `:mutare_active` to a chosen mutant id and builds + runs the query — exactly
  #      what Mutare's runner does per mutant, minus the suite.
  #
  # Baseline is id `0` (the selector's default), so `under(0, …)` runs the *original* query and
  # `under(id, …)` the mutant; a semantic test asserts the two result sets differ in the
  # SQL-meaningful way the mutation predicts.

  alias Mutare.Ecto.TestSupport
  alias Mutare.{Site, Test}

  @repo MyApp.Repo

  @doc """
  Bring up the real `MyApp.Repo` for the semantic suite and seed the read-only fixtures.

  Call once from the semantic test's `setup_all` (not `test_helper.exs`): the DB is only needed by
  this one file, so booting it here keeps every other test run — and the exqlite NIF's runtime cost —
  out of it. `start_supervised!/1` ties the Repo to ExUnit's supervisor, so it lives exactly as long
  as the module's tests and stops cleanly afterward; `on_exit/1` then removes the temp files, the
  `Application` env this set (restoring any prior value), leaving no VM state behind. The
  process-global selection switch needs no cleanup of its own: `under/2` runs every activation
  through `Mutare.Test.with_active_mutant/2`, which restores the prior active id in an `after`
  block, so no test leaks one (and the at-most residual value is baseline `0`, i.e. unset).

  The database is a fresh temp file *carrying the OS pid*, so two concurrent `mix test` runs on one
  host get independent SQLite files instead of clobbering a shared one (`pool_size: 1` + `async:
  false` means a single connection owns the seeded rows within a run). Stale files from a crashed
  prior run with the same pid are removed on the way in.
  """
  @spec start_repo!() :: :ok
  def start_repo! do
    db_path = Path.join(System.tmp_dir!(), "mutare_ecto_semantic_#{System.pid()}.db")
    db_files = [db_path, db_path <> "-wal", db_path <> "-shm"]
    Enum.each(db_files, &File.rm/1)

    # Capture the prior config so `on_exit` can restore it exactly — `Application.put_env` here
    # mutates process-global state, and the harness should leave no VM state behind (same stance
    # as the selection-switch cleanup below).
    prior_env = Application.fetch_env(:mutare_ecto, @repo)

    Application.put_env(:mutare_ecto, @repo,
      database: db_path,
      pool_size: 1,
      journal_mode: :wal,
      log: false,
      stacktrace: true
    )

    ExUnit.Callbacks.start_supervised!(@repo)
    MyApp.Seed.populate!(@repo)

    ExUnit.Callbacks.on_exit(fn ->
      case prior_env do
        {:ok, value} -> Application.put_env(:mutare_ecto, @repo, value)
        :error -> Application.delete_env(:mutare_ecto, @repo)
      end

      Enum.each(db_files, &File.rm/1)
    end)

    :ok
  end

  @doc """
  Render `source` to its metamutant, compile it, and return `{module, sites}`.

  A thin wrapper over `Mutare.Test.compile_metamutant/3`: it threads the plugin's default mutators
  (`TestSupport.mutators/1`) and unwraps the single fixture module. Core compiles the rendered
  metamutant — selector `case`s, woven `dynamic`s, coverage catch-all and all — inside a
  uniquely-named wrapper module (so two fixtures named `defmodule Q` never clash through the global
  `Code.compile_string`), and purges every compiled module on test exit. `sites` are the
  `Mutare.Site`s, used to look up a mutant's id by its logical diff (`site_id/2`).
  """
  @spec compile(String.t()) :: {module(), [Site.t()]}
  def compile(source) do
    {[module], sites} = Test.compile_metamutant(source, TestSupport.mutators([]))
    {module, sites}
  end

  @doc """
  Run `fun` under active mutant `id` and return `MyApp.Repo.all/1` of the query it builds.

  Sets the selection switch via `Mutare.Test.with_active_mutant/2` — which routes through
  `Mutare.Selector` (so it never hardcodes the key) and restores the prior active id afterwards, so
  one test can't leak an active id into the next — for the duration of the build, then runs the
  resulting query against the seeded Repo. `fun` builds and returns an `Ecto.Queryable` (typically
  `fn -> module.some_query() end`).
  """
  @spec under(non_neg_integer(), (-> Ecto.Queryable.t())) :: [term()]
  def under(id, fun) when is_integer(id) and id >= 0 do
    Test.with_active_mutant(id, fn -> @repo.all(fun.()) end)
  end
end
