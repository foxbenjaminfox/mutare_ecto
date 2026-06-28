defmodule HabitTracker.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [HabitTracker.Repo]
    opts = [strategy: :one_for_one, name: HabitTracker.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Self-migrate on boot so the SQLite file (or the in-memory test database)
      # always has the latest schema — no separate migrate step to remember.
      HabitTracker.Release.migrate()
      {:ok, pid}
    end
  end
end
