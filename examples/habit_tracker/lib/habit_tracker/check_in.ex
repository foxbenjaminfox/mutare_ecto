defmodule HabitTracker.CheckIn do
  @moduledoc """
  A single day's progress on a habit: a date, how many times it was done that
  day, and an optional note. At most one check-in per habit per day (enforced by
  a unique index, and used as the upsert target in `HabitTracker.Tracker.check_in/3`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias HabitTracker.Habit

  schema "check_ins" do
    field(:date, :date)
    field(:count, :integer, default: 1)
    field(:note, :string)

    belongs_to(:habit, Habit)

    timestamps()
  end

  @doc "Cast and validate attributes for a check-in."
  def changeset(check_in, attrs) do
    check_in
    |> cast(attrs, [:habit_id, :date, :count, :note])
    |> validate_required([:habit_id, :date])
    |> validate_number(:count, greater_than: 0)
    |> assoc_constraint(:habit)
    |> unique_constraint([:habit_id, :date])
  end
end
