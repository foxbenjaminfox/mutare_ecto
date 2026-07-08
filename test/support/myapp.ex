defmodule MyApp.Repo do
  @moduledoc false
  # A *real* Repo for the semantic-layer tests (`test/mutare/ecto/semantic_test.exs`). `MyApp.Repo`
  # is the module name every other test already uses as a bare symbol inside the source strings it
  # transforms (`{Mutare.Ecto, repo: MyApp.Repo}`); making it an actual Repo here lets the semantic
  # tests run the metamutant queries those strings produce against a live SQL engine — proving the
  # woven `^`/`dynamic` mutants change real result sets, not just that the rewrite compiles. Started
  # + seeded once per test module by `Mutare.Ecto.SemanticHarness.start_repo!/1` from the semantic
  # suite's `setup_all` (not `test_helper.exs` — every other test run stays DB-free).
  #
  # This is the **default** (SQLite via `ecto_sqlite3`): self-contained, no server. Its Postgres twin
  # `MyApp.PgRepo` is defined below. Both are compiled unconditionally — an Ecto repo bakes its
  # adapter in at compile time, so running the same fixtures against two engines needs two modules —
  # and the semantic suite generates one test module per enabled engine, each pointed at the matching
  # repo. `MyApp.Seed` reads `repo.__adapter__()` to emit the right per-engine column types.
  use Ecto.Repo, otp_app: :mutare_ecto, adapter: Ecto.Adapters.SQLite3
end

defmodule MyApp.PgRepo do
  @moduledoc false
  # The Postgres twin of `MyApp.Repo` (via `postgrex`), used by the semantic suite's Postgres test
  # module when Postgres is enabled (`MUTARE_TEST_POSTGRES`; see `Mutare.Ecto.SemanticHarness`). It
  # shares `MyApp`'s adapter-agnostic schemas — only the Repo carries an adapter, and the harness
  # supplies a running server's connection config at `start_repo!/1`. Compiling it needs no server;
  # it stays inert (never started) unless the Postgres module is generated.
  use Ecto.Repo, otp_app: :mutare_ecto, adapter: Ecto.Adapters.Postgres
end

defmodule MyApp.User do
  @moduledoc false
  # The fixture schema the semantic tests mutate queries over. The columns are chosen so each SQL
  # family has a boundary/NULL row that *distinguishes* its mutant from the baseline (see the seed
  # in `test/support/seed.ex`): `age` carries the off-by-one boundary (Comparison/FragmentLiteral),
  # `score` is nullable (NullPredicate/Coalesce), `rating` is a nullable *float* (the FloatLiteral
  # arm, which the integer `score`/`age` columns can't exercise — Ecto rejects a float literal on an
  # integer field), `active`+`age` exercise the Connective, `role` the equality swap and Membership
  # polarity, and `joined_at` — seeded relative to *now*, since `ago`/`from_now` are now-anchored —
  # the Temporal direction flip.
  use Ecto.Schema

  schema "users" do
    field(:name, :string)
    field(:age, :integer)
    field(:active, :boolean)
    field(:role, :string)
    field(:score, :integer)
    field(:rating, :float)
    field(:joined_at, :naive_datetime)
    # `status` is an `Ecto.Enum` — the one place a bare atom literal (`u.status == :active`) is
    # valid, result-affecting Ecto (a string column rejects an atom outright), so it is what lets
    # the AtomLiteral arm's `:active` → `:mutare` swap be proven live: `:mutare` is not a member of
    # the enum, so the mutant query raises when it runs.
    field(:status, Ecto.Enum, values: [:active, :inactive])

    has_many(:posts, MyApp.Post)
  end
end

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
