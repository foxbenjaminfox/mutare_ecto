defmodule Hello.Repo.Migrations.CreateGreetings do
  use Ecto.Migration

  def change do
    create table(:greetings) do
      add(:name, :string, null: false)
      add(:language, :string, default: "en")

      timestamps()
    end
  end
end
