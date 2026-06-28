import Config

config :habit_tracker, ecto_repos: [HabitTracker.Repo]

# One pooled connection keeps SQLite simple. `log: false` keeps the CLI output
# clean (no SQL debug lines); the CLI does its own reporting.
config :habit_tracker, HabitTracker.Repo, pool_size: 1, log: false

if config_env() == :test do
  # `:memory:` gives every `mix test` (and every Mutare worker) its own private,
  # throwaway database — no files, no clashes between parallel runs.
  config :habit_tracker, HabitTracker.Repo, database: ":memory:"
end
