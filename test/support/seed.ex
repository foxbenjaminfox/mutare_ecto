defmodule MyApp.Seed do
  @moduledoc false
  # Creates the fixture tables and seeds the read-only dataset the semantic tests query. Called once
  # from `Mutare.Ecto.SemanticHarness.start_repo!/0` (the semantic suite's `setup_all`) after the Repo
  # starts. The rows are hand-picked so that *every* SQL
  # mutant family the catalog emits flips at least one row relative to the baseline — that boundary
  # is what lets a semantic test prove the injected `dynamic` actually ran:
  #
  #   * Comparison `>`↔`>=`           — ages 18 sit *on* the `> 18` boundary (kept by `>=`, dropped by `>`).
  #   * FragmentLiteral `18`→`19`/`17` — age 19 distinguishes `> 19`; age 17 distinguishes `> 17`.
  #   * Comparison `==`↔`!=` (role)    — admins vs the rest.
  #   * NullPredicate is_nil(score)    — Bob/Dave have NULL score; others don't.
  #   * Connective and↔or              — `active and age > 18` vs `or` admit different rows.
  #   * Membership in↔not in (role)    — role ∈ {admin, mod} vs its complement.
  #   * Arithmetic +↔- / *↔/ (age, score) — Alice's score (100) lifts `age + score` over 100 where
  #                                      the difference falls short; `age * 2 > 40` keeps Bob/Eve
  #                                      where the (integer-)division mutant keeps nobody.
  #   * Coalesce drop (score)          — Bob/Dave's NULL scores take the default the drop removes.
  #   * FloatLiteral (rating)          — `rating > 2.5`→`> 3.5` drops Bob (3.0), the boundary row;
  #                                      a float column, since Ecto rejects a float literal on the
  #                                      integer `score`/`age` columns.
  #   * Temporal ago↔from_now (joined_at) — Frank joined *now* (between the two instants); everyone
  #                                      else ten days back (outside the window either way). Seeded
  #                                      at runtime in `populate!/1`, since the helpers are
  #                                      now-anchored.
  #   * Ordering asc↔desc (age)        — youngest vs oldest sorts to the top.
  #   * Bound limit/offset             — a `limit: 2` window shifts when dropped/bumped.
  #   * JoinType inner↔left            — post P3's `user_id` matches no user (orphan).
  #   * Aggregate sum↔avg (age)        — the two reduce the same column to different numbers (in a
  #                                      `select`, and grouped by `role` in a `having: _ > 25`, where
  #                                      sum keeps admin+user but avg keeps only admin).
  #   * binding_reorder                — a posts self-join on `views` is asymmetric under the swap.
  #
  # The read-only dataset above serves the query families. The one **write-path** family —
  # `:on_conflict` — needs a separate, mutable `accounts` table (UNIQUE `email`), reset to a single
  # baseline row by `reset_accounts!/1` before each upsert so its conflicting writes never touch the
  # query fixtures.

  @users [
    %{id: 1, name: "Alice", age: 18, active: true, role: "admin", score: 100, rating: 4.5},
    %{id: 2, name: "Bob", age: 25, active: true, role: "user", score: nil, rating: 3.0},
    %{id: 3, name: "Carol", age: 17, active: false, role: "mod", score: 50, rating: 2.5},
    %{id: 4, name: "Dave", age: 18, active: false, role: "user", score: nil, rating: nil},
    %{id: 5, name: "Eve", age: 40, active: true, role: "admin", score: 0, rating: 5.0},
    %{id: 6, name: "Frank", age: 19, active: true, role: "user", score: 70, rating: 1.5}
  ]

  @posts [
    %{id: 1, title: "P1", views: 10, published: true, user_id: 1},
    %{id: 2, title: "P2", views: 20, published: false, user_id: 2},
    # Orphan: no user has id 99, so an INNER join drops this row and a LEFT join keeps it.
    %{id: 3, title: "P3", views: 5, published: true, user_id: 99}
  ]

  # The baseline row the on_conflict write tests reset `accounts` to before each activation: a single
  # row on email "a@x" whose `name` the swap is observed through (`:replace_all` rewrites it to the
  # upserted value, `:nothing` leaves it "Original"). Kept off the read-only query dataset entirely.
  @account_baseline %{email: "a@x", name: "Original"}

  @doc "(Re)create the fixture tables — dropping any existing ones first — and insert the seed rows."
  def populate!(repo) do
    create_tables!(repo)
    repo.insert_all(MyApp.User, Enum.map(@users, &put_joined_at/1))
    repo.insert_all(MyApp.Post, @posts)
    :ok
  end

  # `joined_at` is computed per run because `ago`/`from_now` are anchored to *now*: Frank (id 6)
  # joined a minute ago — inside any day-scale window around now — while everyone else joined ten
  # days back, on the historical side of both instants.
  defp put_joined_at(%{id: id} = user) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    offset = if id == 6, do: -60, else: -10 * 24 * 60 * 60
    Map.put(user, :joined_at, NaiveDateTime.add(now, offset, :second))
  end

  @doc """
  Reset the write-path `accounts` table to its single baseline row (email "a@x" → name "Original").

  The on_conflict semantic tests call this before each activation, so a conflicting upsert under one
  mutant id can't leak into the next run — the `accounts` table is theirs alone, never read by the
  query fixtures.
  """
  def reset_accounts!(repo) do
    repo.delete_all(MyApp.Account)
    repo.insert_all(MyApp.Account, [@account_baseline])
    :ok
  end

  defp create_tables!(repo) do
    Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS users", [])
    Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS posts", [])
    Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS accounts", [])

    Ecto.Adapters.SQL.query!(
      repo,
      """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT,
        age INTEGER,
        active INTEGER,
        role TEXT,
        score INTEGER,
        rating REAL,
        joined_at TEXT
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      repo,
      """
      CREATE TABLE posts (
        id INTEGER PRIMARY KEY,
        title TEXT,
        views INTEGER,
        published INTEGER,
        user_id INTEGER
      )
      """,
      []
    )

    # The write-path `accounts` table. The UNIQUE index on `email` is what makes a second insert of
    # the same email a *conflict* the `on_conflict:` option resolves — without it, `conflict_target:
    # :email` has nothing to key off and the upsert just inserts a duplicate.
    Ecto.Adapters.SQL.query!(
      repo,
      """
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY,
        email TEXT,
        name TEXT
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      repo,
      "CREATE UNIQUE INDEX accounts_email_index ON accounts (email)",
      []
    )
  end
end
