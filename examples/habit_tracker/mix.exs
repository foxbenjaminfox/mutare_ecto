defmodule HabitTracker.MixProject do
  use Mix.Project

  # A command-line habit tracker that stores its data in a local SQLite file —
  # a deliberately Ecto-dense app to point the mutator at. It exercises schemas
  # and associations, `Ecto.Enum`, changeset validations, migrations, the query
  # DSL (`where`/`join`/`group_by`/`having`/`order_by`/`limit`), aggregates,
  # `Repo.aggregate`, an upsert (`on_conflict`), and an `Ecto.Multi` transaction.
  #
  # Run the mutator from this directory (Mutare must run as a dependency of the
  # app under test, so the Repo and schemas are loadable):
  #
  #     cd examples/habit_tracker
  #     mix deps.get
  #     mix test          # green baseline
  #     mix mutare        # mutate the data layer and report survivors
  #
  # And use it as an actual CLI (data lands in ./habit_tracker.db):
  #
  #     bin/habit add "Read" --target 1
  #     bin/habit check "Read"
  #     bin/habit stats
  def project do
    [
      app: :habit_tracker,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: HabitTracker.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HabitTracker.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The mutator under test, and the Mutare core it plugs into — path deps to
      # the sibling checkouts for now (pre-release). Both are dev/test tooling.
      {:mutare, path: "../../../mutare", only: [:dev, :test], runtime: false},
      {:mutare_ecto, path: "../..", only: [:dev, :test], runtime: false},
      # Ecto + a self-contained SQLite adapter, so the app needs no database
      # server: data lives in a local file, and the test database is in-memory.
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"}
    ]
  end
end
