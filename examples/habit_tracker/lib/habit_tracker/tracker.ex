defmodule HabitTracker.Tracker do
  @moduledoc """
  The core habit operations: create and archive habits, record check-ins, and
  compute the current streak.

  This is the heart of what the Ecto mutator works on — `where` filters, sort
  orders, a row limit, an upsert, and a transaction — alongside the plain Elixir
  of the streak loop. A surviving mutant here points straight at behaviour no
  test pins down.
  """
  import Ecto.Query

  alias HabitTracker.{CheckIn, Habit, Repo}

  @doc "Create a habit from a map of attributes."
  def create_habit(attrs) do
    %Habit{}
    |> Habit.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Look a habit up by its (unique) name."
  def get_habit(name) do
    Repo.get_by(Habit, name: name)
  end

  @doc """
  All habits, alphabetically. Archived habits are hidden unless `archived: true`.
  """
  def list_habits(opts \\ []) do
    Habit
    |> filter_archived(Keyword.get(opts, :archived, false))
    |> order_by([h], asc: h.name)
    |> Repo.all()
  end

  defp filter_archived(query, true), do: query
  defp filter_archived(query, false), do: where(query, [h], h.archived == false)

  @doc """
  Habits whose cadence is one of `cadences`, alphabetically.

  The filter is a *single* SQL condition combining **membership** (`in`) and
  **connectives** (`and` / `or` / `not`): a habit qualifies when its cadence is in
  the list and it isn't archived (unless `archived: true` is passed). The mutator
  reasons about both under SQL's semantics — not Elixir's, with the `and`/`or`
  swap genuinely three-valued — which is the whole reason a query needs its own mutator.
  """
  def by_cadence(cadences, opts \\ []) do
    include_archived = Keyword.get(opts, :archived, false)

    from(h in Habit,
      where: h.cadence in ^cadences and (^include_archived or not h.archived),
      order_by: [asc: h.name]
    )
    |> Repo.all()
  end

  @doc "Archive a habit (it stays in the database but drops off the active list)."
  def archive_habit(%Habit{} = habit) do
    habit
    |> Habit.changeset(%{archived: true})
    |> Repo.update()
  end

  @doc """
  Update a habit's attributes.

  `Habit.changeset/2` applies `optimistic_lock(:lock_version)`, so if the habit
  was changed by someone else since it was loaded, the update raises
  `Ecto.StaleEntryError` rather than silently overwriting their change.
  """
  def update_habit(%Habit{} = habit, attrs) do
    habit
    |> Habit.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Record progress on a habit for a day.

  At most one check-in exists per habit per day, so a repeat check-in on the same
  date *adds* to that day's count rather than failing — an upsert keyed on the
  `(habit_id, date)` unique index.
  """
  def check_in(%Habit{} = habit, date \\ Date.utc_today(), count \\ 1) do
    %CheckIn{}
    |> CheckIn.changeset(%{habit_id: habit.id, date: date, count: count})
    |> Repo.insert(
      on_conflict: [inc: [count: count]],
      conflict_target: [:habit_id, :date]
    )
  end

  @doc "A habit's most recent check-ins, newest first (default the last 7)."
  def recent_check_ins(%Habit{} = habit, limit \\ 7) do
    from(c in CheckIn,
      where: c.habit_id == ^habit.id,
      order_by: [desc: c.date],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  The current streak: consecutive days up to `today` with a check-in.

  The query gathers the dates; the plain-Elixir loop counts back day by day until
  it hits a gap. Both halves are mutable — the filter and the `Date.add(-1)` step
  alike — so the streak is a good probe of how sharp the tests are.
  """
  def current_streak(%Habit{} = habit, today \\ Date.utc_today()) do
    dates =
      from(c in CheckIn, where: c.habit_id == ^habit.id, select: c.date)
      |> Repo.all()
      |> MapSet.new()

    count_consecutive(today, dates, 0)
  end

  defp count_consecutive(date, dates, streak) do
    if MapSet.member?(dates, date) do
      count_consecutive(Date.add(date, -1), dates, streak + 1)
    else
      streak
    end
  end

  @doc """
  Delete a habit and all of its check-ins, atomically.

  Wrapped in an `Ecto.Multi` transaction so a failure can't leave orphaned
  check-ins behind.
  """
  def delete_habit(%Habit{} = habit) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(:check_ins, from(c in CheckIn, where: c.habit_id == ^habit.id))
    |> Ecto.Multi.delete(:habit, habit)
    |> Repo.transaction()
  end
end
