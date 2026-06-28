defmodule HabitTracker.Repo do
  @moduledoc "The app's Ecto repository, backed by SQLite."
  use Ecto.Repo, otp_app: :habit_tracker, adapter: Ecto.Adapters.SQLite3
end
