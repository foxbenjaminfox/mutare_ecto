defmodule Hello.MixProject do
  use Mix.Project

  # A standalone "hello world" Ecto app — the smallest thing that still has a
  # Repo, a schema, a changeset, and a couple of queries to point Mutare at.
  #
  # Run the Ecto mutator against it *from this directory* (Mutare must run as a
  # dependency of the app under test, so the Repo and schemas are loadable):
  #
  #     cd examples/hello
  #     mix deps.get
  #     mix mutare
  #
  def project do
    [
      app: :hello,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Hello.Application, []}
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
      # Ecto + a self-contained SQLite adapter, so the example needs no database
      # server: the dev database is a local file, the test database is in-memory.
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"}
    ]
  end
end
