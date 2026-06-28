defmodule HabitTracker.Repo.Migrations.CreateHabits do
  use Ecto.Migration

  def change do
    create table(:habits) do
      add(:name, :string, null: false)
      add(:cadence, :string, null: false, default: "daily")
      add(:target, :integer, null: false, default: 1)
      add(:archived, :boolean, null: false, default: false)

      timestamps()
    end

    create(unique_index(:habits, [:name]))
  end
end
