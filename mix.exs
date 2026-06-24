defmodule Mutare.Ecto.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutare_ecto,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Mutation-testing plugin for Ecto — a Mutare custom mutator.",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mutare, path: "../mutare"},
      {:ecto, "~> 3.10"},
      # Semantic-layer tests run actual mutated queries against a real SQL engine. SQLite
      # (via ecto_sqlite3 → ecto_sql + the exqlite NIF) is self-contained — no server to
      # stand up — so the "does the injected `dynamic` actually run" tests work anywhere.
      {:ecto_sql, "~> 3.14", only: :test},
      {:ecto_sqlite3, "~> 0.24", only: :test}
    ]
  end
end
