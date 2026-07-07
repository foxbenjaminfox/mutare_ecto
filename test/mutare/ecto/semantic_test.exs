# The semantic layer of the testing strategy: *does the mutant run?* The unit tests
# (host_test, fragment_test, query_test, …) prove the transform *records* the right Sites and that
# the metamutant *compiles*; these prove a recorded mutant is **live** — that flipping the active id
# changes the SQL the engine runs — by executing real metamutants against a real database.
#
# The whole suite lives in `Mutare.Ecto.SemanticCases` (a `use`-able template) and is instantiated
# once per enabled engine. SQLite is always on (self-contained, the default). Postgres is added when
# `MUTARE_TEST_POSTGRES` is set, as a second module running the identical fixtures against
# `MyApp.PgRepo` and a live server — so a single `mix test` covers one engine or two. Each module is
# `async: false`: they share the process-global `:mutare_active` selection switch, so their tests
# must not interleave.
defmodule Mutare.Ecto.SemanticTest.SQLite do
  use ExUnit.Case, async: false
  use Mutare.Ecto.SemanticCases, repo: MyApp.Repo
end

if Mutare.Ecto.SemanticHarness.postgres_enabled?() do
  defmodule Mutare.Ecto.SemanticTest.Postgres do
    use ExUnit.Case, async: false
    use Mutare.Ecto.SemanticCases, repo: MyApp.PgRepo
  end

  # ===========================================================================
  # Reverse-direction liveness. Every swap family elsewhere in this file is
  # proven in ONE direction. Each reverse is a *distinct* selector branch under
  # its own mutant id, so its delivery is a separate claim — a catalog bug that
  # broke only the reverse arm would pass every forward test. These flip the
  # sibling branch (the emphasis is the equivalence-sensitive families, where a
  # one-armed break is the most dangerous).
  # ===========================================================================

  describe "Comparison — `>=` → `>` (reverse arm of the boundary swap)" do
    test "narrowing >= to > drops the boundary rows the baseline admits" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age >= 18, select: u.id)
        end
        """)

      {baseline, mutant} = observe_ids(mod, sites, {"u.age >= 18", "u.age > 18"})

      # Baseline >= 18 keeps the age-18 rows (Alice, Dave) alongside the strictly-over.
      assert baseline == [1, 2, 4, 5, 6]
      # The `>` mutant drops exactly the two boundary rows.
      assert mutant == [2, 5, 6]
      assert baseline -- mutant == [1, 4]
    end
  end

  describe "Comparison — `!=` → `==` (reverse arm of the equality swap)" do
    test "flipping inequality back to equality returns the complementary roles" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.role != "admin", select: u.id)
        end
        """)

      {baseline, mutant} =
        observe_ids(mod, sites, {~s|u.role != "admin"|, ~s|u.role == "admin"|})

      # Baseline != admin: the four non-admins.
      assert baseline == [2, 3, 4, 6]
      # The `==` mutant returns exactly the admins.
      assert mutant == [1, 5]
    end
  end

  describe "Comparison — `<` ↔ `<=` (both arms — the `<` pair the `>` tests never reach)" do
    test "widening < to <= admits the age-18 boundary rows" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age < 18, select: u.id)
        end
        """)

      {baseline, mutant} = observe_ids(mod, sites, {"u.age < 18", "u.age <= 18"})

      # Baseline < 18: only Carol (17).
      assert baseline == [3]
      # The `<=` mutant additionally admits the two age-18 rows (Alice, Dave).
      assert mutant == [1, 3, 4]
    end

    test "narrowing <= to < drops the age-18 boundary rows" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age <= 18, select: u.id)
        end
        """)

      {baseline, mutant} = observe_ids(mod, sites, {"u.age <= 18", "u.age < 18"})

      assert baseline == [1, 3, 4]
      assert mutant == [3]
    end
  end

  describe "Connective — `or` → `and` (reverse arm of the connective swap)" do
    test "narrowing OR to AND requires both leaves instead of either" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.active or u.age > 30, select: u.id)
        end
        """)

      {baseline, mutant} =
        observe_ids(mod, sites, {"u.active or u.age > 30", "u.active and u.age > 30"})

      # Baseline OR: every active user (Alice, Bob, Eve, Frank) — the over-30 leaf (Eve) is
      # already among them.
      assert baseline == [1, 2, 5, 6]
      # AND keeps only rows satisfying both leaves — active *and* over 30: Eve alone.
      assert mutant == [5]
    end
  end

  describe "Arithmetic — `-` → `+` (reverse arm of the additive swap)" do
    test "flipping the difference to a sum admits the row the subtraction excluded" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.score - u.age > 0, select: u.id)
        end
        """)

      {baseline, mutant} =
        observe_ids(mod, sites, {"u.score - u.age > 0", "u.score + u.age > 0"})

      # score - age > 0 (NULL-score Bob/Dave drop under three-valued logic): Alice 82, Carol 33,
      # Frank 51 clear it; Eve (0 - 40) does not.
      assert baseline == [1, 3, 6]
      # score + age > 0 additionally admits Eve (0 + 40).
      assert mutant == [1, 3, 5, 6]
    end
  end

  describe "Arithmetic — `/` → `*` (reverse arm of the multiplicative swap)" do
    test "flipping the quotient to a product lifts every row over the bound" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age / 2 > 10, select: u.id)
        end
        """)

      {baseline, mutant} = observe_ids(mod, sites, {"u.age / 2 > 10", "u.age * 2 > 10"})

      # age / 2 > 10 (integer division): only Bob (12) and Eve (20).
      assert baseline == [2, 5]
      # age * 2 > 10 clears for every age in the table.
      assert mutant == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "Membership — `not in` → `in` (reverse arm of the polarity swap)" do
    test "flipping non-membership back to membership returns the complementary roles" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.role not in ^["admin", "mod"], select: u.id)
        end
        """)

      {baseline, mutant} =
        observe_ids(
          mod,
          sites,
          {~s(u.role not in ^["admin", "mod"]), ~s(u.role in ^["admin", "mod"])}
        )

      # Baseline not in {admin, mod}: the plain users.
      assert baseline == [2, 4, 6]
      # The `in` mutant returns exactly the admins and mods.
      assert mutant == [1, 3, 5]
    end
  end

  describe "Ordering — `desc` → `asc` (reverse arm of the direction flip)" do
    test "flipping descending back to ascending changes which row sorts to the top" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, order_by: [desc: u.age], limit: 1, select: u.id)
        end
        """)

      {baseline, flipped} = observe_rows(mod, sites, {~r/order_by/, ~r/asc: u.age/})

      # Descending, the oldest (Eve, 40) tops; ascending, the youngest (Carol, 17).
      assert baseline == [5]
      assert flipped == [3]
    end
  end

  describe "QueryTerminal — `last` → `first` (reverse arm of the edge swap)" do
    test "the first mutant returns the opposite edge of the ordering" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.{Repo, User}
          def edge, do: Repo.one(last(User, :age))
        end
        """)

      swap = site_id(sites, {~r/last\(User/, ~r/first\(User/})

      # Baseline `last(_, :age)` orders descending and takes the oldest (Eve); the `first` mutant
      # takes the youngest (Carol).
      assert H.activate(0, fn -> mod.edge() end).id == 5
      assert H.activate(swap, fn -> mod.edge() end).id == 3
    end
  end

  # ===========================================================================
  # Dark families — families the rest of the file exercises only structurally
  # (catalog/compile), now proven live: the untested aggregate/combination arms
  # and the opt-in literal arms and the deferred changeset hook drop.
  # ===========================================================================

  describe "Aggregate — `min` → `max` in `select` (the untested aggregate arm)" do
    test "swapping min for max returns the opposite edge of the column" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, select: min(u.age))
        end
        """)

      {[min], [max]} = observe_rows(mod, sites, {~r/min\(u\.age\)/, ~r/max\(u\.age\)/})

      # min age = Carol (17); max age = Eve (40).
      assert min == 17
      assert max == 40
    end
  end

  # NOTE: the `intersect_all` ↔ `except_all` swap is NOT proven live here — SQLite has no
  # `INTERSECT ALL` / `EXCEPT ALL` (like RIGHT JOIN and ILIKE, it's a non-portable set op the
  # engine rejects at build). Its swap catalog is covered structurally in query_test/clause_test;
  # live coverage of the `_all` pair belongs to a Postgres-backed semantic run.

  describe "BooleanLiteral — a direct `== true` flips to `== false` (opt-in arm)" do
    test "negating the boolean literal returns the unpublished posts instead" do
      {mod, sites} =
        H.compile(
          """
          defmodule Q do
            import Ecto.Query
            alias MyApp.Post
            def q, do: from(p in Post, where: p.published == true, select: p.id)
          end
          """,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:boolean_literal]}]
        )

      {baseline, mutant} =
        observe_ids(mod, sites, {"p.published == true", "p.published == false"})

      # published posts: P1, P3.
      assert baseline == [1, 3]
      # the negated literal selects the unpublished post: P2.
      assert mutant == [2]
    end
  end

  describe "StringLiteral — a string literal collapses to the empty string (opt-in arm)" do
    test "emptying the compared string drops every matching row" do
      {mod, sites} =
        H.compile(
          """
          defmodule Q do
            import Ecto.Query
            alias MyApp.User
            def q, do: from(u in User, where: u.role == "admin", select: u.id)
          end
          """,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:string_literal]}]
        )

      {baseline, mutant} = observe_ids(mod, sites, {~s|u.role == "admin"|, ~s|u.role == ""|})

      # role == "admin": Alice, Eve.
      assert baseline == [1, 5]
      # role == "": no user has an empty role, so the mutant matches nothing.
      assert mutant == []
    end
  end

  describe "FloatLiteral — a non-pinned float literal bumps (distinct from the integer arm)" do
    test "the succ bump past the boundary row drops it" do
      {mod, sites} =
        H.compile(
          """
          defmodule Q do
            import Ecto.Query
            alias MyApp.User
            def q, do: from(u in User, where: u.rating > 2.5, select: u.id)
          end
          """,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:float_literal]}]
        )

      {baseline, mutant} = observe_ids(mod, sites, {"u.rating > 2.5", "u.rating > 3.5"})

      # rating > 2.5 (NULL-rating Dave excluded): Bob 3.0, Alice 4.5, Eve 5.0.
      assert baseline == [1, 2, 5]
      # the succ bump to 3.5 drops the boundary row Bob (rating 3.0).
      assert mutant == [1, 5]
    end
  end

  describe "HookDrop — a dropped `prepare_changes` no longer rewrites the row" do
    # `prepare_changes` runs its fn at Repo time (inside the insert's transaction); the baseline
    # hook overwrites `name`, the mutant (hook stage dropped to identity) leaves the cast value.
    # Observed on the written `accounts` row — the deferred-hook twin of the validation drop.
    @hooked_src """
    defmodule W do
      import Ecto.Changeset
      alias MyApp.{Account, Repo}

      def create do
        %Account{}
        |> cast(%{"email" => "h@x", "name" => "Original"}, [:email, :name])
        |> prepare_changes(fn cs -> put_change(cs, :name, "Hooked") end)
        |> Repo.insert()
      end
    end
    """

    test "the dropped prepare_changes lets the un-rewritten name land" do
      {mod, sites} =
        H.compile(@hooked_src,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:hook_drop]}]
        )

      drop = site_id(sites, {~r/prepare_changes/, ~r/identity/})

      # Baseline: the hook fires at insert time and rewrites the name to "Hooked".
      reset_accounts!()
      assert {:ok, %MyApp.Account{}} = H.activate(0, fn -> mod.create() end)
      assert account("h@x").name == "Hooked"

      # Mutant: the hook stage is dropped, so the cast "Original" lands unchanged.
      reset_accounts!()
      assert {:ok, %MyApp.Account{}} = H.activate(drop, fn -> mod.create() end)
      assert account("h@x").name == "Original"
    end
  end
end
