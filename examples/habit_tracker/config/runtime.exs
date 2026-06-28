import Config

# The dev/prod database is a real SQLite file. Default to ./habit_tracker.db,
# overridable with HABIT_TRACKER_DB so you can point the CLI at any file. Read at
# runtime (not compile time) so the env var takes effect every boot.
if config_env() != :test do
  config :habit_tracker, HabitTracker.Repo,
    database: System.get_env("HABIT_TRACKER_DB", "habit_tracker.db")
end
