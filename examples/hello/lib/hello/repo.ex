defmodule Hello.Repo do
  @moduledoc "The app's Ecto repository, backed by SQLite."
  use Ecto.Repo, otp_app: :hello, adapter: Ecto.Adapters.SQLite3
end
