defmodule HabitTracker.DataCase do
  @moduledoc """
  Test case for anything touching the database.

  The in-memory SQLite database lives in a single pooled connection for the whole
  run, so tests are **not** async; each starts from empty `habits` / `check_ins`
  tables.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import HabitTracker.Fixtures

      alias HabitTracker.{CheckIn, Habit, Repo, Search, Stats, Tracker}
    end
  end

  setup do
    HabitTracker.Repo.delete_all(HabitTracker.CheckIn)
    HabitTracker.Repo.delete_all(HabitTracker.Habit)
    :ok
  end
end
