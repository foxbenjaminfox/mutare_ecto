defmodule HabitTracker.Habit do
  @moduledoc """
  A habit to build: a name, how often it should happen, and a per-period target.

  The `schema` block is off-limits to the mutator (a renamed field is a broken
  schema, not a mutant), but `changeset/2` is fair game — every validation it
  stacks on is a rule Mutare can drop to ask "is this enforced by a test?".
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias HabitTracker.CheckIn

  @cadences [:daily, :weekly]

  schema "habits" do
    field(:name, :string)
    field(:cadence, Ecto.Enum, values: @cadences, default: :daily)
    field(:target, :integer, default: 1)
    field(:archived, :boolean, default: false)
    field(:lock_version, :integer, default: 1)

    has_many(:check_ins, CheckIn)

    timestamps()
  end

  @doc "The cadences a habit may have."
  def cadences, do: @cadences

  @doc "Cast and validate attributes for a habit."
  def changeset(habit, attrs) do
    habit
    |> cast(attrs, [:name, :cadence, :target, :archived])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 40)
    |> validate_inclusion(:cadence, @cadences)
    |> validate_number(:target, greater_than: 0)
    |> unique_constraint(:name)
    |> optimistic_lock(:lock_version)
  end
end
