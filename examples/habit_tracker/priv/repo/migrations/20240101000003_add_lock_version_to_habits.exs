defmodule HabitTracker.Repo.Migrations.AddLockVersionToHabits do
  use Ecto.Migration

  # A separate migration (rather than editing the original) so an existing
  # database picks up the new column too — the realistic way schema evolves.
  def change do
    alter table(:habits) do
      add(:lock_version, :integer, null: false, default: 1)
    end
  end
end
