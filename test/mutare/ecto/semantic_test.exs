defmodule Mutare.Ecto.SemanticTest do
  # The **semantic layer** of `DESIGN.md`'s testing strategy: *does the mutant run?* The unit tests
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
  # `async: false`: the tests share the process-global `Mutare.Selector` active-id switch and a
  # single-connection Repo, so they must not interleave. (No other test executes a metamutant, so
  # there is nothing to race with — but the flag makes the ownership explicit.)
  use ExUnit.Case, async: false

  alias Mutare.Ecto.SemanticHarness, as: H

  # Mutant lookup comes straight from core — the harness owns no lookup helper. In-fragment mutants
  # resolve by their exact `{original, mutated}` diff with `site_id/2`; whole-`from` mutants — whose
  # recorded diff is the entire rewritten query, so siblings share an `original_code` — resolve by a
  # substring predicate with `site_by/3`.
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
    # The uniquely-SQL family: three-valued `IS NULL` flips to `IS NOT NULL`. The result sets are
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

  describe "binding-reorder — swap two binding refs (dynamic-injected)" do
    # The reorder rides the same host: `dynamic([a, b], a.views > b.views)` becomes
    # `dynamic([a, b], b.views > a.views)`. Over an asymmetric posts self-join this selects different
    # pairs — proving the *re-declared* binding list in the woven dynamic is wired to the right rows.
    test "swapping the two bindings reverses which self-join pairs match" do
      {mod, sites} =
        build("""
        defmodule Q do
          import Ecto.Query
          alias MyApp.Post
          def q do
            from a in Post,
              join: b in Post,
              on: a.id < b.id,
              where: a.views > b.views,
              select: {a.id, b.id}
          end
        end
        """)

      baseline = q_under(mod, 0) |> Enum.sort()

      mutant =
        q_under(mod, site_id(sites, {"a.views > b.views", "b.views > a.views"})) |> Enum.sort()

      # a.id<b.id with a.views>b.views: (1,3) 10>5, (2,3) 20>5.
      assert baseline == [{1, 3}, {2, 3}]
      # Swapped to b.views>a.views: only (1,2) 20>10.
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
    # not just in the recorded Site. The mutant renders as `identity()`, so locate it by that token
    # with the same one-and-only-one `site_by` guard.
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

      drop =
        site_by(
          sites,
          "clause-drop (piped where)",
          &(&1.original_code =~ "where(" and &1.mutated_code =~ "identity")
        )

      # With the filter stage dropped, every row survives.
      assert ids(mod, drop.id) == [1, 2, 3, 4, 5, 6]
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

      flip =
        site_by(
          sites,
          "asc→desc",
          &(&1.original_code =~ "order_by" and &1.mutated_code =~ "desc: u.age")
        )

      assert q_under(mod, flip.id) == [5]
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

      bump =
        site_by(
          sites,
          "limit 2→3",
          &(&1.original_code =~ "limit: 2" and &1.mutated_code =~ "limit: 3")
        )

      assert ids(mod, bump.id) == [1, 2, 3]

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
      bump =
        site_by(
          sites,
          "offset 2→3",
          &(&1.original_code =~ "offset: 2" and &1.mutated_code =~ "offset: 3")
        )

      assert ids(mod, bump.id) == [4, 5, 6]

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
      left = site_by(sites, "join→left_join", &(&1.mutated_code =~ "left_join: u in User"))
      mutant = ids(mod, left.id)

      # Inner join: only posts whose user exists (P1→user1, P2→user2).
      assert baseline == [1, 2]
      # Left join additionally keeps the orphan P3 (user_id 99).
      assert mutant == [1, 2, 3]
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
      swap = site_by(sites, "sum→avg", &(&1.mutated_code =~ "avg(u.age)"))
      [avg] = q_under(mod, swap.id)

      # Σ ages over the six users.
      assert sum == 18 + 25 + 17 + 18 + 40 + 19
      # avg = sum / 6 — a different value, and not the integer sum.
      assert avg != sum
      assert_in_delta avg, sum / 6, 0.001
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
end
