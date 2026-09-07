defmodule MyApp.Post do
  @moduledoc false
  # The join fixture: `user_id` may point at no user (JoinType inner↔left changes whether the orphan
  # row survives), and `views` drives the two-binding self-join the binding-reorder mutant runs over.
  # (The Aggregate sum↔avg swap is exercised over `User.age` in the semantic test, not over `views`.)
  use Ecto.Schema

  schema "posts" do
    field(:title, :string)
    field(:views, :integer)
    field(:published, :boolean)
    field(:user_id, :integer)

    # `define_field: false` — `user_id` stays the plain integer column above (the orphan-pointing
    # `99` the seed relies on), while the association still enables `assoc(u, :posts)` joins.
    belongs_to(:user, MyApp.User, define_field: false)
  end
end
