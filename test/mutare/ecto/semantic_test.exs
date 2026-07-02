defmodule Mutare.Ecto.SemanticTest do
  # The **semantic layer** of the testing strategy: *does the mutant run?* The unit tests
  # (host_test, fragment_test, query_test, …) prove the transform *records* the right Sites and that
  # the metamutant *compiles*. They cannot prove the woven mutation is **live** — that flipping the
  # active id actually changes the SQL the engine runs. A rewrite that recorded a perfect Site but
  # spliced an inert `dynamic` would pass every unit test and silently mutate nothing.
  #
  # So these tests close the loop against a real database (SQLite, via `MyApp.Repo`): each builds a
  # real metamutant, compiles it, activates a chosen mutant id (via `Mutare.Selector`, the exact
  # switch the metamutant reads) and runs the query the selector now bakes in, asserting the result
  # set differs from the baseline (id 0) in the way the SQL mutation predicts.
  #
  # The emphasis is the `^`/`dynamic`-**injected** in-fragment families (Comparison, FragmentLiteral,
  # NullPredicate, Connective, Membership, binding-reorder) — the design's reason to exist, where an
  # inert injection is the real risk. The whole-`from` families (filter-drop, Ordering, Bound,
  # JoinType, Aggregate), delivered by core's ordinary in-place selector over full `from(...)`
  # expressions, are covered too: they are mutated queries that must run against the DB just the same.
  #
  # The one **write-path** family is also closed here: an `:on_conflict` swap changes what
  # `Repo.insert/2` *does* on a unique conflict (overwrite vs skip vs raise) rather than which rows a
  # query returns, so its tests use `H.activate/2` (not `H.under/2`) to run the upsert under a mutant
  # id and observe a dedicated `accounts` table — reset to a baseline row before each activation so
  # the conflicting writes never pollute the read-only query fixtures.
  #
  # `async: false`: the tests share the process-global `Mutare.Selector` active-id switch and a
  # single-connection Repo, so they must not interleave. (No other test executes a metamutant, so
  # there is nothing to race with — but the flag makes the ownership explicit.)
  use ExUnit.Case, async: false

  alias Mutare.Ecto.SemanticHarness, as: H

  # Mutant lookup comes straight from core — the harness owns no lookup helper. Most mutants resolve
  # by their `{original, mutated}` diff with `site_id/2`: in-fragment mutants name it exactly (string
  # slots), while whole-`from` mutants — whose recorded diff is the entire rewritten query, so
  # siblings share an `original_code` — name it with `Regex` slots that the mutated half
  # disambiguates. Only the drops, recognized by the *absence* of a token, still need an ad-hoc
  # `site_by/3` predicate.
  import Mutare.Test, only: [site_id: 2, site_by: 3]

  # Start + seed the real `MyApp.Repo` once for this module (and tear it down after). Owning the DB
  # lifecycle here — rather than in `test_helper.exs` — keeps every other test run, and the exqlite
  # NIF's runtime cost, out of it.
  setup_all do: H.start_repo!()

  # Build the metamutant for `source`, returning `{module, sites}`. Every fixture exposes a single
  # 0-arity `q/0` that returns the (full) query, so a test only varies the active id.
  defp build(source), do: H.compile(source)

  # Run fixture `module`'s `q/0` under active mutant `id`, returning the sorted `Repo.all` rows.
  # Sorting makes the result order-insensitive — except the Ordering test, which asserts order and
  # so reads the rows directly via `q_under/2`.
  defp ids(module, id), do: module |> q_under(id) |> Enum.sort()

  defp q_under(module, id), do: H.under(id, fn -> apply(module, :q, []) end)

  # Write-path observation for the `:on_conflict` tests. Unlike the query families, an on_conflict
  # mutant changes what `Repo.insert/2` *does* on a unique conflict — so the test resets the
  # dedicated `accounts` table to its baseline row, runs the upsert under a chosen mutant id, and
  # reads the row's `name` back (or asserts the call raises).
  defp reset_accounts!, do: MyApp.Seed.reset_accounts!(MyApp.Repo)

  defp account_name do
    import Ecto.Query
    MyApp.Repo.one(from(a in MyApp.Account, where: a.email == "a@x", select: a.name))
  end

  # Did `fun` raise? Used instead of `assert_raise SpecificError` so the raise-observed on_conflict
  # test stays stable across the CI matrix's ecto_sqlite3 versions (the exception *type* for a unique
  # violation is adapter-version detail; *that it raises at all* is the live signal).
  defp raises?(fun) do
    fun.()
    false
  rescue
    _ -> true
  end

  describe "Comparison — `>` ↔ `>=` (dynamic-injected)" do
    # `u.age > 18` vs `u.age >= 18` differ only on the boundary rows (age == 18). If the injected
    # `dynamic([u], u.age >= 18)` were inert, the mutant would return the baseline set and this fails.
    test "the >= mutant admits the age-boundary rows the > baseline excludes" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age > 18, select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"u.age > 18", "u.age >= 18"}))

      # Baseline: ages strictly over 18 — Bob(25), Eve(40), Frank(19).
      assert baseline == [2, 5, 6]
      # The `>=` mutant additionally keeps the two age-18 rows (Alice, Dave).
      assert mutant == [1, 2, 4, 5, 6]
      assert mutant -- baseline == [1, 4]
    end
  end

  describe "Comparison — binding-less `as(:_)` condition (empty-binding dynamic)" do
    # The same `>` ↔ `>=` family, but the `where` is written with **no binding list** — it references
    # a *named* binding (`as(:user)`), so the host weaves an empty-binding `dynamic([], …)`. Proves
    # that path is live, not just compile-clean: an inert injection would hand back the baseline set.
    test "the >= mutant of a binding-less named-binding where admits the boundary rows" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q do
            from(u in User, as: :user, select: u.id)
            |> where(as(:user).age > 18)
          end
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"as(:user).age > 18", "as(:user).age >= 18"}))

      # Identical to the binding-form Comparison test above — the empty-binding dynamic runs the same
      # SQL: baseline keeps ages strictly over 18, the `>=` mutant additionally admits the age-18 rows.
      assert baseline == [2, 5, 6]
      assert mutant == [1, 2, 4, 5, 6]
      assert mutant -- baseline == [1, 4]
    end

    test "the same fires in a bare-queryable `from` keyword clause (empty-binding dynamic)" do
      # The `from`-keyword twin: a bare schema source (`from(User, …)`, no `u in User`) with an `as:`
      # and a named-binding `where:`. The host weaves `dynamic([], as(:user).age >= 18)` into the
      # keyword clause — proving that path is live too, not just the standalone/pipe form.
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(User, as: :user, where: as(:user).age > 18, select: as(:user).id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"as(:user).age > 18", "as(:user).age >= 18"}))

      assert baseline == [2, 5, 6]
      assert mutant == [1, 2, 4, 5, 6]
      assert mutant -- baseline == [1, 4]
    end
  end

  describe "Comparison — `==` ↔ `!=` (dynamic-injected)" do
    # The equality arm of the same family: `u.role == "admin"` ↔ `u.role != "admin"`. Every row has a
    # non-null `role`, so the two predicates are exact complements — an inert injection would hand back
    # the baseline admins instead of their complement, and this fails.
    test "flipping equality to inequality returns the complementary roles" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.role == "admin", select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {~s(u.role == "admin"), ~s(u.role != "admin")}))

      # role == "admin": Alice, Eve.
      assert baseline == [1, 5]
      # Its complement — everyone who isn't an admin.
      assert mutant == [2, 3, 4, 6]
    end
  end

  describe "FragmentLiteral — `18` → `19` (dynamic-injected)" do
    # The in-fragment integer literal is the catalog's own (core never sees it). Bumping `18`→`19`
    # must drop the age-19 row — proving the literal the SQL engine compared against actually moved.
    test "raising the literal past 19 drops the age-19 row" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age > 18, select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"u.age > 18", "u.age > 19"}))

      assert baseline == [2, 5, 6]
      # `> 19` excludes Frank (age 19); Bob(25)/Eve(40) remain.
      assert mutant == [2, 5]
      assert baseline -- mutant == [6]
    end
  end

  describe "FragmentLiteral — `18` → `17` / `0` (dynamic-injected)" do
    # The catalog emits the literal's *other* boundary values too — `n-1` and the `0` sentinel, not
    # only `n+1` — so the family isn't proven live by the `>19` case alone. `> 17` lowers the bar onto
    # the age-18 rows; `> 0` drops it below the whole table. Each is a different literal the engine
    # must actually have compared against.
    test "lowering the literal admits the boundary rows; the 0 sentinel admits the whole table" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age > 18, select: u.id)
        end
        """)

      assert ids(mod, 0) == [2, 5, 6]

      # `> 17` keeps everyone over 17 — the age-18 rows (Alice, Dave) join Bob/Eve/Frank; Carol (17)
      # still sits on the boundary, excluded.
      assert ids(mod, site_id(sites, {"u.age > 18", "u.age > 17"})) == [1, 2, 4, 5, 6]
      # `> 0` is below every age in the table — all six rows.
      assert ids(mod, site_id(sites, {"u.age > 18", "u.age > 0"})) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "NullPredicate — `is_nil` ↔ `not is_nil` (dynamic-injected)" do
    # The uniquely-SQL family: `IS NULL` flips to `IS NOT NULL`. The result sets are
    # complements, so an inert injection (returning the baseline) is impossible to miss.
    test "flipping is_nil selects exactly the non-null rows instead" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: is_nil(u.score), select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"is_nil(u.score)", "not is_nil(u.score)"}))

      # Null score: Bob, Dave.
      assert baseline == [2, 4]
      # Its complement — everyone with a score.
      assert mutant == [1, 3, 5, 6]
    end
  end

  describe "Connective — `and` ↔ `or` (dynamic-injected)" do
    # `active AND age>18` → `active OR age>18`. Under SQL's three-valued logic this is a real,
    # killable change; the broadened `or` admits the active-but-not-adult row.
    test "widening the connective to OR admits the active under-19 row" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.active and u.age > 18, select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"u.active and u.age > 18", "u.active or u.age > 18"}))

      # active AND age>18: Bob, Eve, Frank.
      assert baseline == [2, 5, 6]
      # active OR age>18 additionally admits Alice (active, age 18).
      assert mutant == [1, 2, 5, 6]
      assert mutant -- baseline == [1]
    end
  end

  describe "Membership — `in` ↔ `not in` (dynamic-injected)" do
    # `x in ^list` ↔ `x not in ^list`: portable polarity. The pinned list (`^[...]`) is left intact
    # — only the predicate's polarity flips — so the result sets are complements.
    test "flipping membership polarity returns the complementary roles" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.role in ^["admin", "mod"], select: u.id)
        end
        """)

      baseline = ids(mod, 0)

      mutant =
        ids(
          mod,
          site_id(sites, {~s(u.role in ^["admin", "mod"]), ~s(u.role not in ^["admin", "mod"])})
        )

      # role ∈ {admin, mod}: Alice, Carol, Eve.
      assert baseline == [1, 3, 5]
      # The complement: the plain users.
      assert mutant == [2, 4, 6]
    end
  end

  describe "Arithmetic — `+` ↔ `-` (dynamic-injected)" do
    # `u.age + u.score > 100` vs `u.age - u.score > 100` differ on any row whose score is nonzero;
    # the NULL-score rows (Bob, Dave) drop out of both — the swap changes the computed value, never
    # a row's NULL-ness. If the injected dynamic were inert, the mutant would return the baseline.
    test "flipping the sum to a difference drops the row the score lifted over the bound" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age + u.score > 100, select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"u.age + u.score > 100", "u.age - u.score > 100"}))

      # Baseline: only Alice clears 100 (18 + 100 = 118); Carol 67, Eve 40 (score 0 — the additive
      # identity: she is unmoved by the swap), Frank 89.
      assert baseline == [1]
      # `-`: Alice falls to -82 — nothing clears 100.
      assert mutant == []
    end
  end

  describe "Arithmetic — `*` ↔ `/` (dynamic-injected)" do
    # `u.age * 2 > 40` vs `u.age / 2 > 40`: the division mutant runs the *database's* `/` —
    # SQLite's integer division truncates — so the bar effectively moves from age > 20 to age > 80.
    test "flipping the product to a quotient raises the effective bound past every row" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age * 2 > 40, select: u.id)
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"u.age * 2 > 40", "u.age / 2 > 40"}))

      # Baseline: ages over 20 — Bob (25), Eve (40).
      assert baseline == [2, 5]
      # `/ 2 > 40` needs age > 80 — no row qualifies.
      assert mutant == []
    end
  end

  describe "binding-reorder — swap two author-written binding refs (in place)" do
    # The reorder swaps the **author-written** positional list in place — a `where([a, b], …)` whose
    # `[a, b]` the author could have transposed becomes `where([b, a], …)`, leaving the condition body
    # exactly as written. Over an asymmetric posts self-join this selects different pairs, proving the
    # swapped list is wired to the right rows. (A *synthesized* list — `from a in Post, join: b in
    # Post` with no written `[a, b]` — is deliberately not reordered.)
    test "swapping the two bindings reverses which self-join pairs match" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.Post
          def q do
            from(a in Post, join: b in Post, on: a.id < b.id, select: {a.id, b.id})
            |> where([a, b], a.views > b.views)
          end
        end
        """)

      baseline = q_under(mod, 0) |> Enum.sort()

      mutant =
        q_under(mod, site_id(sites, {~r/where\(\[a, b\]/, ~r/where\(\[b, a\]/})) |> Enum.sort()

      # [a, b] with a.views>b.views over a.id<b.id pairs: (1,3) 10>5, (2,3) 20>5.
      assert baseline == [{1, 3}, {2, 3}]
      # Swapped to [b, a] (a now binds the join side, b the source): only (1,2) 20>10.
      assert mutant == [{1, 2}]
    end
  end

  describe "filter-drop — remove a `where` clause (whole-`from`)" do
    # "Is this filter tested?" Dropping the whole `where: u.age > 18` clause widens the result to the
    # entire table. Like the limit/offset drops, the mutant carries no replacement token to match on,
    # so it's located by the *absence* of `where` in its rendered output — with the same
    # one-and-only-one `site_by` guard, so a stray sibling can't be mistaken for it.
    test "dropping the where clause returns the whole table" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age > 18, select: u.id)
        end
        """)

      # Baseline: ages strictly over 18 — Bob(25), Eve(40), Frank(19).
      assert ids(mod, 0) == [2, 5, 6]

      drop =
        site_by(
          sites,
          "filter-drop",
          &(&1.original_code =~ "where: u.age > 18" and not (&1.mutated_code =~ "where"))
        )

      # With the filter gone, every row survives.
      assert ids(mod, drop.id) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "clause-drop — remove a piped `where` stage (standalone/pipe)" do
    # The pipe-form twin of filter-drop (`Mutare.Ecto.ClauseDrop`): `q |> where([u], u.age > 18)`
    # becomes `q |> Function.identity()`. Proves the stage drop is **live** — the dropped `where`
    # actually stops filtering at the engine (after `hoist_pipe` lifts the selector out of the pipe),
    # not just in the recorded Site. The mutant renders as `identity()`, so locate it by that token —
    # the `Regex` mutated-slot of `site_id/2`.
    test "dropping a piped where stage returns the whole table" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, select: u.id) |> where([u], u.age > 18)
        end
        """)

      # Baseline: ages strictly over 18 — Bob(25), Eve(40), Frank(19).
      assert ids(mod, 0) == [2, 5, 6]

      drop = site_id(sites, {~r/where\(/, ~r/identity/})

      # With the filter stage dropped, every row survives.
      assert ids(mod, drop) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "Ordering — `asc` ↔ `desc` (whole-`from`)" do
    # A pinned-keyword direction flip. With `limit: 1` the top row flips from youngest to oldest —
    # observable proof the mutated `order_by` reached the engine.
    test "flipping the sort direction changes which row sorts to the top" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, order_by: [asc: u.age], limit: 1, select: u.id)
        end
        """)

      assert q_under(mod, 0) == [3]

      flip = site_id(sites, {~r/order_by/, ~r/desc: u.age/})

      assert q_under(mod, flip) == [5]
    end
  end

  describe "Bound — drop / bump `limit` (whole-`from`)" do
    test "dropping the limit returns the whole table; +1 widens the window by one row" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, limit: 2, order_by: [asc: u.id], select: u.id)
        end
        """)

      assert ids(mod, 0) == [1, 2]

      bump = site_id(sites, {~r/limit: 2/, ~r/limit: 3/})

      assert ids(mod, bump) == [1, 2, 3]

      # The drop has no `limit` left in its rendered mutant — locate it by that absence. `site_by`
      # gives this the same one-and-only-one guard as `site_id`, so a stray sibling can't slip past.
      drop =
        site_by(
          sites,
          "limit-drop",
          &(&1.original_code =~ "limit: 2" and not (&1.mutated_code =~ "limit"))
        )

      assert ids(mod, drop.id) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "Bound — drop / bump `offset` (whole-`from`)" do
    # `offset` is the other half of the Bound family (`@bound_keys ~w(limit offset)a`): it slides the
    # window's start rather than its size. SQLite only honours `OFFSET` alongside a `LIMIT`, so the
    # fixture carries a wide `limit: 10` that never clips the six rows — every observable shift is the
    # `offset` mutation's doing.
    test "bumping the offset slides the window; dropping it returns from the top" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, order_by: [asc: u.id], limit: 10, offset: 2, select: u.id)
        end
        """)

      # offset 2: skip Alice/Bob, keep the rest.
      assert ids(mod, 0) == [3, 4, 5, 6]
      # offset 3 skips one more from the top.
      bump = site_id(sites, {~r/offset: 2/, ~r/offset: 3/})

      assert ids(mod, bump) == [4, 5, 6]

      # The drop has no `offset` left in its rendered mutant — locate it by that absence (the `limit`
      # is still there, so the limit-drop site, whose mutant keeps `offset: 2`, can't match). Same
      # one-and-only-one `site_by` guard as the limit-drop case.
      drop =
        site_by(
          sites,
          "offset-drop",
          &(&1.original_code =~ "offset: 2" and not (&1.mutated_code =~ "offset"))
        )

      assert ids(mod, drop.id) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "JoinType — inner ↔ left (whole-`from`)" do
    # Cardinality change: an INNER join drops the orphan post (user_id 99 matches no user); the LEFT
    # mutant keeps it. A strong, killable mutation that must hit the DB to show.
    test "the left-join mutant keeps the orphan row the inner join drops" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.{Post, User}
          def q do
            from p in Post, join: u in User, on: u.id == p.user_id, select: p.id
          end
        end
        """)

      baseline = ids(mod, 0)
      left = site_id(sites, {~r/join: u in User/, ~r/left_join: u in User/})
      mutant = ids(mod, left)

      # Inner join: only posts whose user exists (P1→user1, P2→user2).
      assert baseline == [1, 2]
      # Left join additionally keeps the orphan P3 (user_id 99).
      assert mutant == [1, 2, 3]
    end
  end

  describe "Combination — `intersect` ↔ `except` (whole-`from` clause key)" do
    # `A INTERSECT B` and `A EXCEPT B` partition the left query's rows (A∩B vs A∖B are disjoint), so
    # the swap flips the result to the *other* side of the partition — impossible to confuse with an
    # inert rewrite. Left: active users {1,2,5,6}; right: adults (age > 18) {2,5,6}.
    test "swapping intersect for except returns the left-only rows instead of the shared ones" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User

          def q do
            adults = from(u in User, where: u.age > 18, select: u.id)
            from(u in User, where: u.active, select: u.id, intersect: ^adults)
          end
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {~r/intersect: \^adults/, ~r/except: \^adults/}))

      # active ∩ adults: Bob, Eve, Frank.
      assert baseline == [2, 5, 6]
      # active ∖ adults: only Alice (active but sitting on the age-18 boundary).
      assert mutant == [1]
    end
  end

  describe "Combination — piped `intersect` ↔ `except` (standalone/pipe macro rename)" do
    # The standalone/pipe twin: the swap renames the *macro call itself* (`|> intersect(^adults)` →
    # `|> except(^adults)`), delivered by the in-place selector over the pipe stage — a different
    # rewrite path from the clause-key swap above, so its liveness is proven separately.
    test "renaming the piped intersect to except flips the partition side" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User

          def q do
            adults = from(u in User, where: u.age > 18, select: u.id)

            from(u in User, where: u.active, select: u.id)
            |> intersect(^adults)
          end
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {~r/intersect\(\^adults\)/, ~r/except\(\^adults\)/}))

      assert baseline == [2, 5, 6]
      assert mutant == [1]
    end
  end

  describe "Regression — multi-condition join `on:` keeps a green baseline (BUG-multi-condition-join-on)" do
    # The host wraps even the *baseline* branch in `^dynamic`, so hosting an `on:` that isn't its
    # join's whole, top-level on-expression corrupts mutant id 0 itself: Ecto folds a join's
    # multiple/implicit on-conditions into one `and`, and a `^dynamic` operand of that `and` raises
    # ("dynamic expressions can only be interpolated at the top level…") — aborting `mix mutare`
    # before any mutant runs. `assert_compiles` can't catch it (the metamutant compiles fine; the
    # error is at query-build time), so only running the baseline against the DB proves the fix.

    test "two `on:` keys on one join — the baseline builds and runs" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.{Post, User}
          def q do
            from u in User,
              inner_join: p in Post,
              on: p.user_id == u.id,
              on: p.published == true,
              select: u.id
          end
        end
        """)

      # The inner join keeps users with a *published* post: Alice (P1 published); Bob's P2 is not.
      assert ids(mod, 0) == [1]
    end

    test "an `assoc` join with an explicit `on:` — the baseline builds and runs" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q do
            from u in User,
              inner_join: p in assoc(u, :posts),
              on: p.published == true,
              select: u.id
          end
        end
        """)

      # Same result through the assoc join (implicit `p.user_id == u.id`) plus the explicit filter.
      assert ids(mod, 0) == [1]
    end

    test "a standalone `assoc` join with an `on:` — the baseline builds and runs" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q do
            User
            |> join(:inner, [u], p in assoc(u, :posts), on: p.published == true)
            |> select([u], u.id)
          end
        end
        """)

      assert ids(mod, 0) == [1]
    end
  end

  describe "Aggregate — `sum` ↔ `avg` in `select` (whole-`from`)" do
    test "swapping sum for avg reduces the column to a different number" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, select: sum(u.age))
        end
        """)

      [sum] = q_under(mod, 0)
      swap = site_id(sites, {~r/sum\(u\.age\)/, ~r/avg\(u\.age\)/})
      [avg] = q_under(mod, swap)

      # Σ ages over the six users.
      assert sum == 18 + 25 + 17 + 18 + 40 + 19
      # avg = sum / 6 — a different value, and not the integer sum.
      assert avg != sum
      assert_in_delta avg, sum / 6, 0.001
    end
  end

  describe "Aggregate — `sum` ↔ `avg` in a `having` (dynamic-injected)" do
    # The hosted twin of the select-aggregate swap: an aggregate inside a `having` rides the same
    # `^`/`dynamic` host as the operator swaps, so an inert injection is the real risk here too.
    # Grouped by role, `having: sum(u.age) > 25` keeps the groups whose ages *total* over 25 —
    # admin (18+40=58) and user (25+18+19=62); swapping `sum` for `avg` re-asks the question of the
    # group's *mean* (admin 29, user ≈20.7), which drops `user` while keeping `admin`. The surviving
    # group set changes, proving the woven `dynamic([u], avg(u.age) > 25)` actually ran.
    test "swapping sum for avg in a having changes which groups survive" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q do
            from u in User,
              group_by: u.role,
              having: sum(u.age) > 25,
              select: u.role
          end
        end
        """)

      baseline = ids(mod, 0)
      mutant = ids(mod, site_id(sites, {"sum(u.age) > 25", "avg(u.age) > 25"}))

      # sum(age) per role over 25: admin 58, user 62 clear it; mod 17 doesn't.
      assert baseline == ["admin", "user"]
      # avg(age) per role over 25: only admin (29); user (≈20.7) and mod (17) fall below.
      assert mutant == ["admin"]
    end
  end

  describe "on_conflict — `:replace_all` → `:nothing` (Repo write, content-observed)" do
    # The write-path twin of the query-family liveness tests. An `:on_conflict` mutant changes what
    # `Repo.insert/2` *does* on a unique conflict rather than which rows a query returns: `:replace_all`
    # resolves the conflict to an UPDATE (overwriting the row), the `:nothing` mutant skips it. Observed
    # through the row's `name` after the upsert — no raise involved — so it's robust across the CI
    # Ecto/adapter matrix. Restricting to `families: [:on_conflict]` records exactly the one swap site
    # (no `:persistence` sibling on the same insert to disambiguate).
    @replace_all_upsert """
    defmodule W do
      alias MyApp.{Account, Repo}

      def upsert do
        Repo.insert(%Account{email: "a@x", name: "New"},
          on_conflict: :replace_all,
          conflict_target: :email
        )
      end
    end
    """

    test "replace_all overwrites the conflicting row; the :nothing mutant leaves it untouched" do
      {mod, sites} =
        H.compile(@replace_all_upsert,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:on_conflict]}]
        )

      swap = site_id(sites, {~r/on_conflict: :replace_all/, ~r/on_conflict: :nothing/})

      # Baseline (:replace_all): the conflict resolves to an UPDATE → the row's name becomes "New".
      reset_accounts!()
      H.activate(0, fn -> mod.upsert() end)
      assert account_name() == "New"

      # Mutant (:nothing): the conflict is silently skipped → the row keeps its baseline "Original".
      reset_accounts!()
      H.activate(swap, fn -> mod.upsert() end)
      assert account_name() == "Original"
    end
  end

  describe "on_conflict — `:nothing` → `:raise` (Repo write, raise-observed)" do
    # The other behavioural axis: `:nothing` swallows a unique conflict (returns `{:ok, _}`, leaving
    # the row); the `:raise` mutant lets the conflict raise. Asserting *that the call raises* — not a
    # specific exception type — keeps the test stable across the matrix's ecto_sqlite3 versions while
    # still proving the swapped atom reached the engine.
    @skip_upsert """
    defmodule W do
      alias MyApp.{Account, Repo}

      def upsert do
        Repo.insert(%Account{email: "a@x", name: "New"},
          on_conflict: :nothing,
          conflict_target: :email
        )
      end
    end
    """

    test ":nothing returns {:ok, _} on a conflict; the :raise mutant raises and persists nothing" do
      {mod, sites} =
        H.compile(@skip_upsert,
          mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: [:on_conflict]}]
        )

      flip = site_id(sites, {~r/on_conflict: :nothing/, ~r/on_conflict: :raise/})

      # Baseline (:nothing): the conflict is skipped — an `{:ok, _}` result and the row unchanged.
      reset_accounts!()
      assert {:ok, _} = H.activate(0, fn -> mod.upsert() end)
      assert account_name() == "Original"

      # Mutant (:raise): the same insert now raises on the unique conflict; the row is untouched.
      reset_accounts!()
      assert raises?(fn -> H.activate(flip, fn -> mod.upsert() end) end)
      assert account_name() == "Original"
    end
  end

  describe "the switch itself" do
    # A guard test for the whole harness: baseline (id 0) really is the *original* query, and an id
    # outside the recorded set falls through the selector's catch-all to the baseline too — so a
    # "mutant differs from baseline" assertion elsewhere can't be an artifact of id 0 being special.
    test "id 0 and an unknown id both run the original query" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User
          def q, do: from(u in User, where: u.age > 18, select: u.id)
        end
        """)

      assert ids(mod, 0) == [2, 5, 6]
      assert ids(mod, 999_999) == [2, 5, 6]
    end
  end

  describe "Regression — named source rebind + positional join (baseline correctness)" do
    # BUG-from_bindings-named-rebind-join: when a `from` rebinds a *named* source and adds a
    # *positional* join, the woven `dynamic` binding list used to place the join at position 0 — named
    # binds consume no position, so a lone trailing join read as "first positional". Because the host
    # wraps even the *original* branch in `dynamic([…], original)`, this corrupted the **baseline**
    # (id 0), not just the mutants: `mix mutare` aborts with "baseline suite is not green". The fix
    # anchors the join to the tail with `...`. This test pins the baseline to the *source* semantics —
    # the one thing the unit `assert_compiles` could never catch (the bad query compiled fine).
    test "the baseline reproduces the source query, not a join-at-position-0 corruption" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User

          def q do
            base = from(u in User, as: :usr)

            from([usr: u] in base,
              inner_join: u2 in User,
              on: u2.id != u.id,
              where: u2.age == u.age,
              select: u2.id
            )
          end
        end
        """)

      # The hand-written source semantics (no weave): for each user, the *other* users sharing its
      # age. Only Alice(18)/Dave(18) pair up; no one else shares an age — so the source returns [1, 4].
      reference = Enum.sort(reference_same_age_peers())

      assert reference == [1, 4]
      # The baseline (id 0) must equal the source. Pre-fix the woven `[u2, usr: u]` collapsed the
      # predicate to `usr.age == usr.age` (a tautology keeping every joined pair), so it diverged.
      assert ids(mod, 0) == reference
    end

    # The hand-written twin of the fixture's `q/0`, run directly (no metamutant) — the exact semantics
    # the woven baseline must reproduce.
    defp reference_same_age_peers do
      import Ecto.Query
      base = from(u in MyApp.User, as: :usr)

      MyApp.Repo.all(
        from([usr: u] in base,
          inner_join: u2 in MyApp.User,
          on: u2.id != u.id,
          where: u2.age == u.age,
          select: u2.id
        )
      )
    end
  end

  describe "Regression — explicit `...` in a source rebind (baseline correctness)" do
    # The sibling of the named-rebind bug: an *explicit* `...` in the source pattern (`[..., c] in q`)
    # declares `c` as the query's last binding, but the host used to drop the `...` when re-declaring
    # the woven dynamic, re-binding `c` to position 0. With a 3-binding base (only the last skipped to)
    # the woven `where` then filtered the *wrong* binding — corrupting the baseline while `c` in the
    # (un-woven) `select` stayed correct. The fix preserves the source `...` in the woven binding list.
    test "the baseline filters the binding the source `...` selects, not position 0" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User

          def q do
            base =
              from(u1 in User,
                join: u2 in User, on: u2.id == u1.id + 1,
                join: u3 in User, on: u3.id == u1.id + 2
              )

            from([..., c] in base, where: c.age > 18, select: c.id)
          end
        end
        """)

      # base rows (u1, u2=u1+1, u3=u1+2): (1,2,3) (2,3,4) (3,4,5) (4,5,6). `[..., c]` binds c → u3.
      # Keeping c.age > 18 (u3 ∈ {Eve 40, Frank 19}) leaves rows (3,4,5) and (4,5,6) → c.id ∈ [5, 6].
      reference = Enum.sort(reference_last_binding())

      assert reference == [5, 6]

      # Pre-fix the woven `[c]` filtered position 0 (u1.age > 18 → only Bob's row (2,3,4)), so the
      # baseline returned that row's c.id (u3 = 4) — i.e. [4], diverging from the source.
      assert ids(mod, 0) == reference
    end

    # The hand-written twin of the fixture's `q/0`, run directly (no metamutant).
    defp reference_last_binding do
      import Ecto.Query

      base =
        from(u1 in MyApp.User,
          join: u2 in MyApp.User,
          on: u2.id == u1.id + 1,
          join: u3 in MyApp.User,
          on: u3.id == u1.id + 2
        )

      MyApp.Repo.all(from([..., c] in base, where: c.age > 18, select: c.id))
    end
  end

  describe "Regression — an implicit-anchor source rebind (BUG-named-binding-misresolution)" do
    # The reported bug at the DB layer: composing `from(u1 in base, inner_join: u4 …, where: u4 …)`
    # onto an external `base` that carries *hidden* bindings. `u4` is appended at the tail (position 3
    # here), but the host wove `dynamic([u1, u4], …)` — binding `u4` to position 1 (`base`'s hidden
    # `u2`) — instead of `dynamic([u1, ..., u4], …)`. The hosted `where` then filtered the wrong
    # binding, corrupting the *baseline*. Unlike the `[..., c]` sibling above, the source here writes
    # *no* `...`: the host must insert one for the composed (variable) source itself.
    test "the baseline filters the appended join, not a hidden base binding" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User

          def q do
            base =
              from(u1 in User,
                join: u2 in User, on: u2.id == u1.id + 1,
                join: u3 in User, on: u3.id == u1.id + 2
              )

            from(u1 in base,
              inner_join: u4 in User,
              on: u4.id == u1.id,
              where: u4.age > 18,
              select: u1.id
            )
          end
        end
        """)

      # `u4` is `u1` itself (`u4.id == u1.id`), so `u4.age > 18` keeps the u1 rows over 18. base exists
      # for u1 ∈ {1,2,3,4} (it needs u1+1 and u1+2 as user ids); of those only Bob (u1=2, age 25)
      # clears 18 → [2].
      reference = Enum.sort(reference_appended_join())

      assert reference == [2]

      # Pre-fix the woven `[u1, u4]` bound `u4` to base's hidden `u2` (id u1+1), filtering the wrong
      # user — a corrupted baseline. The anchored `[u1, ..., u4]` filters the real appended join.
      assert ids(mod, 0) == reference
    end

    # The hand-written twin of the fixture's `q/0`, run directly (no metamutant).
    defp reference_appended_join do
      import Ecto.Query

      base =
        from(u1 in MyApp.User,
          join: u2 in MyApp.User,
          on: u2.id == u1.id + 1,
          join: u3 in MyApp.User,
          on: u3.id == u1.id + 2
        )

      MyApp.Repo.all(
        from(u1 in base,
          inner_join: u4 in MyApp.User,
          on: u4.id == u1.id,
          where: u4.age > 18,
          select: u1.id
        )
      )
    end
  end

  describe "Regression — a function-call source rebind (composed query via a call, not a var)" do
    # The same baseline corruption as the variable-source sibling above, reached through a *function
    # call* source (`from(u1 in base(), …)`) instead of a bound variable. A call is just as opaque a
    # composed query — it can return one carrying hidden bindings — yet the pre-fix `composed?` check
    # recognized only a bare variable, so it dropped the tail anchor and wove `dynamic([u1, u4], …)`,
    # binding `u4` to `base`'s hidden `u2` and corrupting the baseline. The anchored `[u1, ..., u4]`
    # filters the real appended join. `assert_compiles` can't catch this — the wrong baseline compiles.
    test "the baseline filters the appended join, not a hidden base binding" do
      {mod, _sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.User

          def q do
            from(u1 in base(),
              inner_join: u4 in User,
              on: u4.id == u1.id,
              where: u4.age > 18,
              select: u1.id
            )
          end

          defp base do
            from(u1 in User,
              join: u2 in User, on: u2.id == u1.id + 1,
              join: u3 in User, on: u3.id == u1.id + 2
            )
          end
        end
        """)

      # The same query as the variable-source sibling — only `base` is reached through a call. The
      # reference keeps u1 ∈ {Bob} → [2].
      assert ids(mod, 0) == reference_appended_join()
    end
  end
end
