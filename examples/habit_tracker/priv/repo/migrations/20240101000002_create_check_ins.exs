defmodule HabitTracker.Repo.Migrations.CreateCheckIns do
  use Ecto.Migration

  def change do
    create table(:check_ins) do
      add(:habit_id, references(:habits, on_delete: :delete_all), null: false)
      add(:date, :date, null: false)
      add(:count, :integer, null: false, default: 1)
      add(:note, :string)

      timestamps()
    end

    create(index(:check_ins, [:habit_id]))
    # One check-in per habit per day — also the conflict target for the upsert.
    create(unique_index(:check_ins, [:habit_id, :date]))
  end
end
