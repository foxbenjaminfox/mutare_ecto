defmodule HabitTracker.Stats do
  @moduledoc """
  Analytics over the habit log: leaderboards, totals, and gaps.

  This is the dense end of the query DSL — joins, `group_by`/`having`, aggregates
  (`sum`/`avg`/`count`), a `left_join` with `is_nil`, a date-range filter, and an
  explicit NULLS-placement ordering — exactly the surface where the Ecto mutator
  earns its keep. Swap `sum` for `avg`, an inner join for a left one, `>=` for `>`,
  or move where NULLs sort, and only a sharp test will notice.
  """
  import Ecto.Query

  alias HabitTracker.{CheckIn, Habit, Repo}

  @doc """
  Habits ranked by total check-in count, most active first.

  Only habits with at least `min_total` total are listed (a `having` over the
  grouped sum), and archived habits are excluded.
  """
  def leaderboard(min_total \\ 1) do
    from(h in Habit,
      join: c in assoc(h, :check_ins),
      where: h.archived == false,
      group_by: h.id,
      having: sum(c.count) >= ^min_total,
      order_by: [desc: sum(c.count)],
      select: %{name: h.name, total: sum(c.count), days: count(c.id)}
    )
    |> Repo.all()
  end

  @doc "Habit names with more than `min_days` distinct check-in days."
  def busy_habits(min_days \\ 1) do
    from(h in Habit,
      join: c in assoc(h, :check_ins),
      group_by: h.id,
      having: count(c.id) > ^min_days,
      select: h.name
    )
    |> Repo.all()
  end

  @doc "The total of every count a habit has logged (0 when it has none)."
  def total_count(%Habit{} = habit) do
    from(c in CheckIn, where: c.habit_id == ^habit.id)
    |> Repo.aggregate(:sum, :count)
    |> Kernel.||(0)
  end

  @doc "The average daily count for a habit (nil when it has no check-ins)."
  def average_count(%Habit{} = habit) do
    from(c in CheckIn, where: c.habit_id == ^habit.id)
    |> Repo.aggregate(:avg, :count)
  end

  @doc """
  Habits that have never been checked in — a `left_join` that keeps the habits
  with no matching check-in, then filters to exactly those (`is_nil`).
  """
  def never_checked_in do
    from(h in Habit,
      left_join: c in assoc(h, :check_ins),
      where: is_nil(c.id),
      order_by: [asc: h.name],
      select: h
    )
    |> Repo.all()
  end

  @doc """
  Habits ranked by their most recent activity — latest check-in first — with the
  dormant ones (never checked in) listed last.

  A `left_join` keeps the never-checked-in habits, whose `max(c.date)` is then
  `NULL`; the explicit `:desc_nulls_last` is the author saying *where* those NULLs
  sort — at the bottom. That NULLS placement is its **own** mutation axis, separate
  from the `:desc` direction: flipping it to `:desc_nulls_first` only changes the
  result once a dormant habit (a NULL date) is actually in the data — the same
  orphan-row condition the `left_join` → inner-join swap needs. Two equivalence-
  sensitive families, one missing fixture.
  """
  def by_recent_activity do
    from(h in Habit,
      left_join: c in assoc(h, :check_ins),
      group_by: h.id,
      order_by: [desc_nulls_last: max(c.date)],
      select: %{name: h.name, last_active: max(c.date)}
    )
    |> Repo.all()
  end

  @doc """
  The names of habits checked in on or after `date`, alphabetically.

  Built in the composable form with an **ellipsis binding**: `where([..., c], ...)`
  reaches the check-in binding — the *last* one — without naming the `habits`
  binding ahead of it. That's the positional idiom for "filter on the
  most-recently-joined table" in query code that doesn't want to spell out every
  binding before the one it cares about.
  """
  def active_since(date) do
    Habit
    |> join(:inner, [h], c in assoc(h, :check_ins))
    |> where([..., c], c.date >= ^date)
    |> distinct(true)
    |> order_by([h], asc: h.name)
    |> select([h], h.name)
    |> Repo.all()
  end

  @doc "Check-ins on or after `cutoff`, newest first, with their habit preloaded."
  def check_ins_since(cutoff) do
    from(c in CheckIn,
      where: c.date >= ^cutoff,
      order_by: [desc: c.date],
      preload: [:habit]
    )
    |> Repo.all()
  end
end
