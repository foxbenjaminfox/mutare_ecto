defmodule HabitTracker.Release do
  @moduledoc """
  Database bring-up helper — run the migrations programmatically.

  The CLI is a single self-contained tool with no separate `mix ecto.migrate`
  step, so the app migrates itself to the latest version on boot (see
  `HabitTracker.Application`). The Repo is already started by the supervision tree
  at that point, so this runs the migrator against it directly.
  """

  @app :habit_tracker

  @doc "Run all pending migrations for every configured repo."
  def migrate do
    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      Ecto.Migrator.run(repo, :up, all: true, log: false)
    end

    :ok
  end
end
