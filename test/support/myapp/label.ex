defmodule MyApp.Label do
  @moduledoc false
  # Keyword-filter columns of each kind the pair routing tells apart: a primitive type, whose
  # literals interpolate unchanged, and types whose `cast/1` may not (a custom type, a
  # parameterized one, `:binary_id`). Routing-only: no table is seeded.
  use Ecto.Schema

  schema "labels" do
    field(:plain, :string)
    field(:folded, MyApp.FoldedString)
    field(:status, Ecto.Enum, values: [:active, :archived])
    field(:uid, :binary_id)
  end
end
