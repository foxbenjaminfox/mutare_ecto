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

  import ExUnit.Assertions

  alias Mutare.Ecto.TestSupport

  @repo MyApp.Repo

  @doc """
  Bring up the real `MyApp.Repo` for the semantic suite and seed the read-only fixtures.

  Call once from the semantic test's `setup_all` (not `test_helper.exs`): the DB is only needed by
  this one file, so booting it here keeps every other test run — and the exqlite NIF's runtime cost —
  out of it. `start_supervised!/1` ties the Repo to ExUnit's supervisor, so it lives exactly as long
  as the module's tests and stops cleanly afterward; `on_exit/1` then removes the temp files, the
  process-global `:mutare_active` switch, and the `Application` env this set (restoring any prior
  value), leaving no VM state behind.

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
    # as the `:mutare_active` cleanup below).
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
      :persistent_term.erase(:mutare_active)

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

  The module name is made unique per call (the metamutant compiles through the global
  `Code.compile_string`, so two fixtures named `defmodule Q` would otherwise clash), then the
  rendered metamutant — selector `case`s, woven `dynamic`s, coverage catch-all and all — is compiled
  into a live module. `sites` are the `Mutare.Site`s, used to look up a mutant's id by its logical
  diff (`site_id/2`).
  """
  @spec compile(String.t(), keyword()) :: {module(), [Mutare.Site.t()]}
  def compile(source, opts \\ []) do
    {metamutant, sites, _next} =
      Mutare.transform_string(source, mutators: TestSupport.mutators(opts), expand_uses: true)

    {compile_module!(TestSupport.uniquify_module(metamutant)), sites}
  end

  @doc """
  Run `fun` under active mutant `id` and return `MyApp.Repo.all/1` of the query it builds.

  `id` is written to `:persistent_term` (`:mutare_active`) — the exact switch the metamutant's
  selector reads — for the duration of the build, then reset to the baseline `0` so one test can't
  leak an active id into the next. `fun` builds and returns an `Ecto.Queryable` (typically
  `fn -> module.some_query() end`); the harness runs it against the seeded Repo.
  """
  @spec under(non_neg_integer(), (-> Ecto.Queryable.t())) :: [term()]
  def under(id, fun) when is_integer(id) and id >= 0 do
    :persistent_term.put(:mutare_active, id)

    try do
      @repo.all(fun.())
    after
      :persistent_term.put(:mutare_active, 0)
    end
  end

  @doc """
  The id of the (single) site whose recorded logical diff is `{original_substr, mutated_substr}`.

  Sites carry the *logical* before/after (`u.age > 18` → `u.age >= 18`), never the `dynamic`/`^`
  scaffolding, so a semantic test names the mutant the way the report would and the harness resolves
  it to the id the selector switches on. Fails loudly (listing the candidates) when nothing matches —
  a guard against a fixture whose mutation silently stopped being emitted.
  """
  @spec site_id([Mutare.Site.t()], {String.t(), String.t()}) :: pos_integer()
  def site_id(sites, {original_substr, mutated_substr}) do
    sites
    |> site_by(inspect({original_substr, mutated_substr}), fn s ->
      s.original_code =~ original_substr and s.mutated_code =~ mutated_substr
    end)
    |> Map.fetch!(:id)
  end

  @doc """
  The single site satisfying `pred`, returned whole (read `.id` for the selector id).

  The same one-and-only-one guarantee as `site_id/2`, for the cases the `{original, mutated}`
  substring pair can't express — chiefly the `limit`-drop mutant, recognized by the *absence* of
  `limit` in its rendered output rather than the presence of a token. `label` names the lookup in
  the failure message. Flunks (listing the candidates) on zero *or* multiple matches, so an ad-hoc
  `Enum.find` can't silently resolve to the first of several — a fixture whose mutation stopped
  being emitted, or grew an unexpected sibling, fails loudly instead.
  """
  @spec site_by([Mutare.Site.t()], String.t(), (Mutare.Site.t() -> boolean())) :: Mutare.Site.t()
  def site_by(sites, label, pred) when is_function(pred, 1) do
    case Enum.filter(sites, pred) do
      [site] ->
        site

      [] ->
        flunk("""
        no site matching #{label}
        recorded sites:
        #{render_sites(sites)}
        """)

      many ->
        flunk("""
        ambiguous: #{length(many)} sites match #{label}
        #{render_sites(many)}
        """)
    end
  end

  defp render_sites(sites) do
    Enum.map_join(sites, "\n", fn s ->
      "  id=#{s.id} #{s.mutator}: #{inspect(s.original_code)} -> #{inspect(s.mutated_code)}"
    end)
  end

  # === internals =============================================================

  defp compile_module!(source) do
    [{module, _bin} | _] = Code.compile_string(source)
    module
  end
end
