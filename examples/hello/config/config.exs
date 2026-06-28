import Config

config :hello, ecto_repos: [Hello.Repo]

# One pooled connection keeps SQLite simple: the in-memory test database lives in
# that single connection for the whole run, and the dev file needs no pool tuning.
config :hello, Hello.Repo, pool_size: 1

if config_env() == :test do
  # `:memory:` gives every `mix test` (and every Mutare worker) its own private,
  # throwaway database — no files to clean up, no clashes between parallel runs.
  config :hello, Hello.Repo, database: ":memory:", log: false
else
  # Dev/prod: a real SQLite file in the project directory.
  config :hello, Hello.Repo, database: "hello.db"
end
