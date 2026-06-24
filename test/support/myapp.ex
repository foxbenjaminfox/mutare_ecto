defmodule MyApp.Repo do
  @moduledoc false
  # A *real* Repo for the semantic-layer tests (`test/mutare/ecto/semantic_test.exs`), backed by
  # SQLite via `ecto_sqlite3`. `MyApp.Repo` is the module name every other test already uses as a
  # bare symbol inside the source strings it transforms (`{Mutare.Ecto, repo: MyApp.Repo}`); making
  # it an actual Repo here lets the semantic tests run the metamutant queries those strings produce
  # against a live SQL engine — proving the woven `^`/`dynamic` mutants change real result sets, not
  # just that the rewrite compiles. Started + seeded once by `Mutare.Ecto.SemanticHarness.start_repo!/0`
  # from the semantic suite's `setup_all` (not `test_helper.exs` — every other test run stays DB-free).
  use Ecto.Repo, otp_app: :mutare_ecto, adapter: Ecto.Adapters.SQLite3
end

defmodule MyApp.User do
  @moduledoc false
  # The fixture schema the semantic tests mutate queries over. The columns are chosen so each SQL
  # family has a boundary/NULL row that *distinguishes* its mutant from the baseline (see the seed
  # in `test/support/seed.ex`): `age` carries the off-by-one boundary (Comparison/FragmentLiteral),
  # `score` is nullable (NullPredicate), `active`+`age` exercise the Connective, `role` the equality
  # swap and Membership polarity.
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :age, :integer
    field :active, :boolean
    field :role, :string
    field :score, :integer
  end
end

defmodule MyApp.Post do
  @moduledoc false
  # The join fixture: `user_id` may point at no user (JoinType inner↔left changes whether the orphan
  # row survives), and `views` drives the two-binding self-join the binding-reorder mutant runs over.
  # (The Aggregate sum↔avg swap is exercised over `User.age` in the semantic test, not over `views`.)
  use Ecto.Schema

  schema "posts" do
    field :title, :string
    field :views, :integer
    field :published, :boolean
    field :user_id, :integer
  end
end
