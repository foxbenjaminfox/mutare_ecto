defmodule Mutare.Ecto.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/foxbenjaminfox/mutare_ecto"

  # A few *typespecs* in visible modules reference a hidden internal type
  # (`Mutare.Ecto.Clause`/`Query`/`BindingReorder` return `Mutare.Ecto.AST.QueryCall.t`;
  # `Mutare.Ecto.Host` returns `Mutare.Ecto.Host.Target.t`; `Mutare.Ecto.Fragment`
  # takes `Mutare.Ecto.Config.t`). ExDoc autolinks types in typespecs unconditionally, so a
  # reference to a hidden type is silenced on the *referencing* module instead — keep this list tight.
  @typespec_refs_to_hidden ~w(
    Mutare.Ecto.BindingReorder
    Mutare.Ecto.Clause
    Mutare.Ecto.Fragment
    Mutare.Ecto.Host
    Mutare.Ecto.Query
  )

  def project do
    [
      app: :mutare_ecto,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Mutation-testing plugin for Ecto — a Mutare custom mutator.",
      package: package(),
      lockfile: System.get_env("MIX_LOCKFILE", "mix.lock"),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Hex package metadata. The `mutare` core is still a `path:` dependency, so an actual
  # `mix hex.publish` stays blocked until Mutare itself ships to Hex — this section keeps
  # the manifest (license, links, the files that ship) ready for that day. Only runtime
  # and doc artifacts ship: `lib/`, the README extra ExDoc renders, the license, and
  # `mix.exs` — never the test suite, fixtures, the examples app, the CI config, or the
  # agent-facing CLAUDE.md.
  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Benjamin Fox"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mutare, path: "../mutare"}
      | ecto_deps() ++
          [
            # Static-analysis tooling: lints (credo) and type/discrepancy checks (dialyxir,
            # the Mix wrapper around Erlang's Dialyzer). Dev only, never shipped or fetched by tests.
            {:credo, "~> 1.7", only: :dev, runtime: false},
            {:dialyxir, "~> 1.4", only: :dev, runtime: false},
            # Doc generation. Dev only, never shipped or fetched by tests.
            {:ex_doc, "~> 0.34", only: :dev, runtime: false}
          ]
    ]
  end

  # Ecto and its SQL/SQLite drivers. The version requirements are env-overridable so the
  # CI compatibility matrix can sweep every supported Ecto minor line (see ci.yml); local
  # and the default test/check jobs fall back to the locked stack.
  #
  # ecto_sql + ecto_sqlite3 back the semantic-layer tests, which run actual mutated queries
  # against a real SQL engine. SQLite (via ecto_sqlite3 → ecto_sql + the exqlite NIF) is
  # self-contained — no server to stand up — so the "does the injected `dynamic` actually
  # run" tests work anywhere.
  #
  # Setting ECTO_GIT_BRANCH builds against the development tip of Ecto/Ecto SQL instead of a
  # published release: `override: true` lets the git checkouts win over the Hex requirement
  # ecto_sqlite3 declares transitively. That job is allowed to fail in CI.
  defp ecto_deps do
    case System.get_env("ECTO_GIT_BRANCH") do
      branch when branch in [nil, ""] ->
        [
          {:ecto, System.get_env("ECTO_REQUIREMENT", "~> 3.12")},
          {:ecto_sql, System.get_env("ECTO_SQL_REQUIREMENT", "~> 3.14"), only: :test},
          {:ecto_sqlite3, System.get_env("ECTO_SQLITE3_REQUIREMENT", "~> 0.24"), only: :test}
        ]

      branch ->
        [
          {:ecto, github: "elixir-ecto/ecto", branch: branch, override: true},
          {:ecto_sql,
           github: "elixir-ecto/ecto_sql", branch: branch, override: true, only: :test},
          {:ecto_sqlite3, System.get_env("ECTO_SQLITE3_REQUIREMENT", "~> 0.24"), only: :test}
        ]
    end
  end

  # ExDoc configuration. `mix docs` renders to `doc/` (gitignored). README is the
  # landing page. Modules are grouped along the three delivery buckets; `@moduledoc false`
  # plumbing never appears, and the moduledocs avoid prose-linking to it.
  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"],
      skip_undefined_reference_warnings_on: &(&1 in @typespec_refs_to_hidden),
      groups_for_modules: [
        "Mutator front": [
          Mutare.Ecto
        ],
        "Repo & changeset mutators": [
          Mutare.Ecto.RepoAggregate,
          Mutare.Ecto.RepoWrite,
          Mutare.Ecto.Changeset,
          Mutare.Ecto.QueryTerminal
        ],
        "Query-DSL mutators": [
          Mutare.Ecto.Query,
          Mutare.Ecto.Clause,
          Mutare.Ecto.ClauseDrop,
          Mutare.Ecto.BindingReorder
        ],
        "Hosted in-fragment mutations": [
          Mutare.Ecto.Host,
          Mutare.Ecto.Host.Routing,
          Mutare.Ecto.Fragment
        ]
      ]
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
