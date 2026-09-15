defmodule Hello.Greeting do
  @moduledoc """
  A greeting addressed to someone, in some language.

  The `schema` block is left untouched by the Ecto mutator (a renamed field is a
  broken schema, not an interesting mutant). Mutare can drop each validation in
  the *changeset* to check whether tests cover it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "greetings" do
    field(:name, :string)
    field(:language, :string, default: "en")
    timestamps()
  end

  @doc "Cast and validate attributes for a greeting."
  def changeset(greeting, attrs) do
    greeting
    |> cast(attrs, [:name, :language])
    |> validate_required([:name])
    |> validate_length(:name, min: 2)
  end
end
