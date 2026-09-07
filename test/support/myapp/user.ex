# One schema per file, as in any Ecto app: Ecto 3.12 validates an association's target at the
# owning schema's `@after_compile`, and a target defined *later in the same file* does not exist
# yet at that moment ("associated schema MyApp.Post does not exist" — the CI minimum-version row
# failed on exactly that). Across files the parallel compiler resolves the `User` ↔ `Post` cycle.
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
