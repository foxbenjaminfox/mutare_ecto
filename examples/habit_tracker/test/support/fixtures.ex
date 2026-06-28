defmodule HabitTracker.Fixtures do
  @moduledoc "Convenience builders for tests."
  alias HabitTracker.{Habit, Repo, Tracker}

  @doc "Create a habit, raising on invalid attrs."
  def habit_fixture(attrs \\ %{}) do
    {:ok, habit} =
      attrs
      |> Enum.into(%{name: "Read", cadence: :daily, target: 1})
      |> Tracker.create_habit()

    habit
  end

  @doc "Insert a check-in directly (bypassing the upsert) on `date` with `count`."
  def check_in_fixture(%Habit{} = habit, date, count \\ 1) do
    {:ok, check_in} = Tracker.check_in(habit, date, count)
    check_in
  end

  @doc "Reload a habit from the database."
  def reload(%Habit{} = habit), do: Repo.get(Habit, habit.id)

  @doc "Render a changeset's errors as a `%{field => [messages]}` map."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
