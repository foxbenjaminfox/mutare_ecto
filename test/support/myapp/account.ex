defmodule MyApp.Account do
  @moduledoc false
  # The **write-path** fixture for the `:on_conflict` semantic tests — kept separate from the
  # read-only `users`/`posts` dataset so a conflicting insert never pollutes the query fixtures.
  # `email` carries a UNIQUE index (created by the seed), so a second insert of the same email is a
  # conflict the `on_conflict:` option resolves; `name` is the field the swap is observed through
  # (`:replace_all` overwrites it, `:nothing` leaves it). Each on_conflict test resets the table to a
  # single baseline row via `MyApp.Seed.reset_accounts!/1` before each activation, so the write tests
  # are independent of each other and of the query suite.
  use Ecto.Schema

  schema "accounts" do
    field(:email, :string)
    field(:name, :string)
  end
end
