defmodule Hello do
  @moduledoc """
  A tiny greetings "context": create greetings and read them back.

  Every database-touching function here is something the Ecto mutator can change
  in a SQL-meaningful way — a filter, a sort direction, a row limit — so a
  surviving mutant points straight at a test that wouldn't notice the change.
  """
  import Ecto.Query
  alias Hello.{Greeting, Repo}

  @doc "A plain, database-free greeting string."
  def greet(name), do: "Hello, #{name}!"

  @doc "Insert a greeting from a map of attributes."
  def add_greeting(attrs) do
    %Greeting{}
    |> Greeting.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The most recently inserted greetings, newest first.

  `order_by` and `limit` are both mutable: Mutare can flip `:desc` to `:asc`,
  nudge the limit by one, or drop it entirely.
  """
  def recent_greetings(limit \\ 5) do
    Greeting
    |> order_by([g], desc: g.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Every greeting in `language`, sorted by name.

  The `where g.language == ^language` comparison is the SQL heart of the example:
  Mutare swaps `==` for `!=`, and only a test that asserts the *wrong* languages
  are excluded will catch it.
  """
  def greetings_in(language) do
    from(g in Greeting,
      where: g.language == ^language,
      order_by: [asc: g.name]
    )
    |> Repo.all()
  end
end
