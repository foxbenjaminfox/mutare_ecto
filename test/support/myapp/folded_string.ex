defmodule MyApp.FoldedString do
  @moduledoc false
  # A custom type whose `cast/1` changes a value its `dump/1` accepts unchanged: a written
  # literal reaches the query dumped only, an interpolated parameter cast first. So a keyword
  # filter pair on such a column is left unmutated (`Mutare.Ecto.Host.Routing`): interpolating
  # it would bind another value at baseline.
  use Ecto.Type

  def type, do: :string
  def cast(value) when is_binary(value), do: {:ok, String.downcase(value)}
  def cast(_value), do: :error
  def load(value), do: {:ok, value}
  def dump(value) when is_binary(value), do: {:ok, value}
  def dump(_value), do: :error
end
