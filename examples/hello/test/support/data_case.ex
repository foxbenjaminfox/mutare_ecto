defmodule Hello.DataCase do
  @moduledoc """
  Test case for anything that touches the database.

  The in-memory SQLite database lives in a single pooled connection for the whole
  run, so tests are **not** async and each one starts from a clean `greetings`
  table.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      alias Hello.Repo
    end
  end

  setup do
    Hello.Repo.delete_all(Hello.Greeting)
    :ok
  end
end
