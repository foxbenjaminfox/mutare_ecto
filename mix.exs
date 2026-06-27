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
      lockfile: System.get_env("MIX_LOCKFILE", "mix.lock"),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mutare, path: System.get_env("MUTARE_PATH", "../mutare")},
      {:ecto, System.get_env("ECTO_REQUIREMENT", "~> 3.12")},
      # Semantic-layer tests run actual mutated queries against a real SQL engine. SQLite
      # (via ecto_sqlite3 → ecto_sql + the exqlite NIF) is self-contained — no server to
      # stand up — so the "does the injected `dynamic` actually run" tests work anywhere.
      {:ecto_sql, System.get_env("ECTO_SQL_REQUIREMENT", "~> 3.14"), only: :test},
      {:ecto_sqlite3, System.get_env("ECTO_SQLITE3_REQUIREMENT", "~> 0.24"), only: :test},
      # Static-analysis tooling: lints (credo) and type/discrepancy checks (dialyxir,
      # the Mix wrapper around Erlang's Dialyzer). Dev only, never shipped or fetched by tests.
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  # `mix check` is the single quality gate: formatting, lint, and type analysis.
  # Any non-zero step aborts the rest, so a green run means all three passed.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "credo",
        "dialyzer"
      ]
    ]
  end

  # PLTs land in priv/plts so they can be cached (e.g. in CI) instead of being
  # rebuilt every run. :ex_unit/:mix aren't in the dep tree but the lib and tests
  # touch them, so they're added explicitly to keep Dialyzer from flagging them.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:ex_unit, :mix],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end
end
