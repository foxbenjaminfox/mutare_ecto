defmodule Mutare.Ecto.SemanticCases do
  @moduledoc false
  # The shared body of the semantic-layer suite (*does the mutant run?*), factored into a
  # `use`-able template so it can be instantiated **once per enabled engine**. Each generated test
  # module (`Mutare.Ecto.SemanticTest.SQLite`, and — when Postgres is enabled — `.Postgres`) sets
  # `@repo` to its Repo module and runs these exact fixtures against it. `@repo` is a per-module
  # constant, so there is no loop/late-binding hazard: every helper, mutator config, and fixture
  # source string below reads the one repo the module was instantiated with.
  #
  # Why a `use` template rather than a `for` inside one module: two engines need two *modules* (an
  # Ecto repo bakes its adapter in at compile time), and separate modules also mean the describe/test
  # names never collide, with no per-test disambiguation. See `Mutare.Ecto.SemanticHarness` for the
  # flip-and-compare mechanics each helper composes.
  #
  # **Dialect-only arms proven at the unit/config layer, not here.** Three catalog arms are
  # non-portable, so they have no liveness test on the always-on SQLite engine — and since the
  # Postgres module runs these *same* fixtures, it adds none either: `like`↔`ilike` (Postgres-only),
  # the RIGHT-join arm of `:join_type` (`left`↔`right`, `full`→`right`; Postgres/MySQL), and
  # `intersect_all`↔`except_all` (Postgres/MySQL). Each is covered at the source/routing layer by
  # `fragment_test`/`host_test`/`query_test`/`config_test`; a Postgres-gated liveness fixture for
  # them is a known future extension (it would need a `dialects:`-configured mutator run under a
  # `@repo.__adapter__() == Ecto.Adapters.Postgres` runtime guard).
  defmacro __using__(opts) do
    # The quote is deliberately the whole suite — this module exists to inject it verbatim into each
    # per-engine test module — so the long-block heuristic doesn't apply.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote location: :keep do
      @repo unquote(opts[:repo])

      alias Mutare.Ecto.SemanticHarness, as: H

      # Mutant lookup comes straight from core — the harness owns no lookup helper. Most tests are the
      # standard flip-and-compare pair, resolved and observed in one step by core's `observe_mutant/3`
      # (through `H.observe/3` / the `observe_*` helpers below): the mutant named by its
      # `{original, mutated}` diff — in-fragment mutants name it exactly (string slots), while
      # whole-`from` mutants, whose recorded diff is the entire rewritten query so siblings share an
      # `original_code`, name it with `Regex` slots the mutated half disambiguates — and the baseline
      # run first, pinned to core's baseline selection. `site_id/2` remains for a build observed under
      # several mutant ids; only the drops, recognized by the *absence* of a token, still need an
      # ad-hoc `site_by/3` predicate.
      import Mutare.Test, only: [site_id: 2, site_by: 3]

      # Start + seed the real `MyApp.Repo` once for this module (and tear it down after). Owning the DB
      # lifecycle here — rather than in `test_helper.exs` — keeps every other test run, and the exqlite
      # NIF's runtime cost, out of it.
      setup_all do: H.start_repo!(@repo)

      # Build the metamutant for `source`, returning `{module, sites}`. Every fixture exposes a single
      # 0-arity `q/0` that returns the (full) query, so a test only varies the active id.
      defp build(source), do: H.compile(source, repo: @repo)

      # Run fixture `module`'s `q/0` under active mutant `id`, returning the sorted `Repo.all` rows.
      # These per-id observations serve the tests `observe_ids/3` can't: a mutant located by
      # `site_by/3` (the drops), a build observed under several ids, and the baseline-only regressions.
      defp ids(module, id), do: module |> q_under(id) |> Enum.sort()

      defp q_under(module, id), do: H.under(@repo, id, fn -> apply(module, :q, []) end)

      # The flip-and-compare pair for fixture `module`'s `q/0` (`H.observe/3` — core's
      # `observe_mutant/3` over the harness's Repo observation), both sides sorted like `ids/2`.
      # The workhorse of the query-family tests.
      defp observe_ids(module, sites, pattern) do
        {baseline, mutant} = observe_rows(module, sites, pattern)
        {Enum.sort(baseline), Enum.sort(mutant)}
      end

      # The unsorted twin, for observations where row order or a single computed value is the point.
      defp observe_rows(module, sites, pattern) do
        H.observe(@repo, sites, pattern, fn -> apply(module, :q, []) end)
      end

      # Write-path observation for the `:on_conflict` tests. Unlike the query families, an on_conflict
      # mutant changes what `Repo.insert/2` *does* on a unique conflict — so the test resets the
      # dedicated `accounts` table to its baseline row, runs the upsert under a chosen mutant id, and
      # reads the row's `name` back (or asserts the call raises).
      defp reset_accounts!, do: MyApp.Seed.reset_accounts!(@repo)

      defp account_name do
        import Ecto.Query
        @repo.one(from(a in MyApp.Account, where: a.email == "a@x", select: a.name))
      end

      # The account row for `email`, or `nil` — the persistence/validation tests observe a write
      # through the row's presence/absence, not through the call's return shape alone.
      defp account(email) do
        import Ecto.Query
        @repo.one(from(a in MyApp.Account, where: a.email == ^email))
      end

      # Normalize an adapter-typed aggregate value for numeric comparison: SQLite's AVG is a float,
      # other adapters may hand back a Decimal.
      defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
      defp to_number(n) when is_number(n), do: n * 1.0

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

          {baseline, mutant} = observe_ids(mod, sites, {"u.age > 18", "u.age >= 18"})

          # Baseline: ages strictly over 18 — Bob(25), Eve(40), Frank(19).
          assert baseline == [2, 5, 6]
          # The `>=` mutant additionally keeps the two age-18 rows (Alice, Dave).
          assert mutant == [1, 2, 4, 5, 6]
          assert mutant -- baseline == [1, 4]
        end
      end

      describe "Island sub-contract — a core mutant of a pin interior (dynamic-injected)" do
        # A `^(8 + 10)` interior is ordinary Elixir the host sub-contracts to core's generation
        # (`Mutare.Analyze.expression_mutations/3`), relaying each rebuild through its own weave with
        # `producer:` attribution. Compile-level attribution is SubcontractTest's; here we prove the
        # relayed mutant is **live**: flipping the active id changes the *parameter* the query binds,
        # and the engine's result set moves exactly as core's literal bump predicts.
        test "the literal-succ island mutant tightens the bound the baseline parameter set" do
          {mod, sites} =
            H.compile(
              """
              defmodule Q do
                import Ecto.Query
                alias MyApp.User
                def q, do: from(u in User, where: u.age > ^(8 + 10), select: u.id)
              end
              """,
              mutators: [:literal, {Mutare.Ecto, repo: @repo}]
            )

          {baseline, mutant} =
            observe_ids(mod, sites, {"u.age > ^(8 + 10)", "u.age > ^(8 + 11)"})

          # Baseline binds 18 — ages strictly over 18: Bob(25), Eve(40), Frank(19).
          assert baseline == [2, 5, 6]

          # The island mutant binds 19, so the boundary row Frank(19) falls out — the parameter the
          # woven dynamic interpolates really did change at runtime.
          assert mutant == [2, 5]
        end

        # The whole-call twin: the same island inside a **free-standing** `dynamic/1,2` is
        # sub-contracted through the same seam but delivered as an in-place whole-call rewrite
        # (`Mutare.Ecto.Dynamic` — no weave; the call sits in expression position and the mutated
        # `DynamicExpr` is spliced downstream by the raw `where(^d)`). Proves *that* delivery is
        # live too: the rebuilt call binds a different parameter and the result set moves.
        test "the literal-succ island mutant of a spliced free-standing dynamic is live" do
          {mod, sites} =
            H.compile(
              """
              defmodule Q do
                import Ecto.Query
                alias MyApp.User
                def q do
                  d = dynamic([u], u.age > ^(8 + 10))
                  from(u in User, select: u.id) |> where(^d)
                end
              end
              """,
              mutators: [:literal, {Mutare.Ecto, repo: @repo}]
            )

          site =
            site_id(sites, {"dynamic([u], u.age > ^(8 + 10))", "dynamic([u], u.age > ^(8 + 11))"})

          baseline = ids(mod, 0)
          mutant = ids(mod, site)

          # Baseline binds 18 — ages strictly over 18: Bob(25), Eve(40), Frank(19).
          assert baseline == [2, 5, 6]

          # The relayed mutant binds 19 — the boundary row Frank(19) falls out, exactly as in the
          # hosted twin above.
          assert mutant == [2, 5]
        end
      end

      describe "Shorthand interpolation — a core literal mutant of a `where: [col: v]` value" do
        # The `{:keyword, …}`/`:interpolated` routing hands a shorthand scalar to *core's* literal
        # family, delivered `^`-pinned by core. The routing is the plugin's, the delivery core's —
        # and neither unit suite proves the pinned parameter actually *binds*. Same closure as the
        # island sub-contract test: flip the core mutant and watch the bound value move the rows.
        test "the literal-succ mutant of a shorthand value changes which rows match" do
          {mod, sites} =
            H.compile(
              """
              defmodule Q do
                import Ecto.Query
                alias MyApp.User
                def q, do: from(u in User, where: [age: 18], select: u.id)
              end
              """,
              mutators: [:literal, {Mutare.Ecto, repo: @repo}]
            )

          {baseline, mutant} = observe_ids(mod, sites, {"18", "19"})

          # Baseline binds 18 — the equality keeps Alice and Dave (both 18).
          assert baseline == [1, 4]
          # The mutant binds 19 — only Frank matches; the parameter, not the source, changed.
          assert mutant == [6]
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

          {baseline, mutant} =
            observe_ids(mod, sites, {"as(:user).age > 18", "as(:user).age >= 18"})

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

          {baseline, mutant} =
            observe_ids(mod, sites, {"as(:user).age > 18", "as(:user).age >= 18"})

          assert baseline == [2, 5, 6]
          assert mutant == [1, 2, 4, 5, 6]
          assert mutant -- baseline == [1, 4]
        end
      end

      describe "Comparison — free-standing `dynamic` (whole-call in-place delivery)" do
        # The build-site path (`Mutare.Ecto.Dynamic`): the condition lives in a *free-standing*
        # `dynamic/2` spliced later with `where(q, ^d)`. Unlike every family above, the mutant is not
        # woven into a query clause — the whole `dynamic(...)` call is swapped by core's ordinary
        # in-place selector, so this proves that delivery builds a *live* `DynamicExpr` (an inert
        # rewrite would hand back the baseline set) and that the splice site composes it unchanged.
        test "the >= mutant of a prebuilt dynamic admits the boundary rows" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User

              def q do
                d = dynamic([u], u.age > 18)
                from(u in User, where: ^d, select: u.id)
              end
            end
            """)

          {baseline, mutant} =
            observe_ids(mod, sites, {"dynamic([u], u.age > 18)", "dynamic([u], u.age >= 18)"})

          # Same data as the hosted `>`↔`>=` test above: the `>=` mutant admits the age-18 rows.
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

          {baseline, mutant} =
            observe_ids(mod, sites, {~s(u.role == "admin"), ~s(u.role != "admin")})

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

          {baseline, mutant} = observe_ids(mod, sites, {"u.age > 18", "u.age > 19"})

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

          {baseline, mutant} =
            observe_ids(mod, sites, {"is_nil(u.score)", "not is_nil(u.score)"})

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

          {baseline, mutant} =
            observe_ids(mod, sites, {"u.active and u.age > 18", "u.active or u.age > 18"})

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

          {baseline, mutant} =
            observe_ids(
              mod,
              sites,
              {~s(u.role in ^["admin", "mod"]), ~s(u.role not in ^["admin", "mod"])}
            )

          # role ∈ {admin, mod}: Alice, Carol, Eve.
          assert baseline == [1, 3, 5]
          # The complement: the plain users.
          assert mutant == [2, 4, 6]
        end
      end

      describe "Membership — drop a written in-list element (dynamic-injected)" do
        # A *written* list drops one member per mutant — shrinking the set the engine matches against.
        # The fixture writes the list with pinned elements (`[^admin, ^mod]`): the drop is a mutation
        # of the written list either way, and pinned elements are what actually *runs* on SQLite —
        # a fully-literal list (`in ["admin", "mod"]`) fails to dump on this adapter even unmutated
        # (no array type), so the literal-list form is exercised at the catalog/compile level instead.
        test "dropping one member keeps only the other member's rows" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User

              def q do
                admin = "admin"
                mod = "mod"
                from(u in User, where: u.role in [^admin, ^mod], select: u.id)
              end
            end
            """)

          {baseline, dropped} =
            observe_ids(mod, sites, {~s(u.role in [^admin, ^mod]), ~s(u.role in [^admin])})

          # role ∈ {admin, mod}: Alice, Carol, Eve.
          assert baseline == [1, 3, 5]
          # Without ^mod, Carol drops out.
          assert dropped == [1, 5]
        end
      end

      describe "Membership — `exists` ↔ `not exists` (dynamic-injected)" do
        # The subquery cousin of the `in` polarity flip, correlated via `parent_as`: the baseline keeps
        # users who have at least one post; the mutant keeps exactly the complement. If the injected
        # `dynamic(not exists(...))` were inert, the mutant would return the baseline set.
        test "flipping exists returns the users without posts instead" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.{Post, User}

              def q do
                from u in User,
                  as: :user,
                  where: exists(from(p in Post, where: parent_as(:user).id == p.user_id)),
                  select: u.id
              end
            end
            """)

          {baseline, mutant} =
            observe_ids(mod, sites, {~r/\Aexists\(from/, ~r/\Anot exists\(from/})

          # Users with a post: Alice (P1), Bob (P2). P3's user_id (99) matches nobody.
          assert baseline == [1, 2]
          # The complement: everyone else.
          assert mutant == [3, 4, 5, 6]
        end
      end

      describe "Subquery interior — an inner `where` mutation is woven and live" do
        # The inner condition of a correlated `exists` subquery is mutated in place and delivered through
        # the same host weave as the polarity flip. `p.views > 10` vs `>= 10` differ only on the boundary
        # post (P1, views == 10, user 1): the `>` baseline excludes user 1 (their only post sits exactly on
        # the bound), the `>=` mutant admits them. If the injected inner mutant were inert, both would agree.
        test "flipping the subquery's inner comparison changes which users the exists keeps" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.{Post, User}

              def q do
                from u in User,
                  as: :user,
                  where:
                    exists(
                      from(p in Post,
                        where: parent_as(:user).id == p.user_id and p.views > 10
                      )
                    ),
                  select: u.id
              end
            end
            """)

          {baseline, mutant} = observe_ids(mod, sites, {~r/p\.views > 10/, ~r/p\.views >= 10/})

          # Baseline: only Bob (user 2 — P2, views 20 > 10). User 1's only post (P1) sits on the bound.
          assert baseline == [2]
          # The `>=` mutant additionally admits user 1 (P1's views == 10, the bound).
          assert mutant == [1, 2]
        end
      end

      describe "Membership — `like` ↔ `ilike` (dialect-only, Postgres)" do
        # `like` is case-sensitive, `ilike` case-insensitive — a Postgres-only swap gated by
        # `dialects: [:postgres]`. `like(u.name, "a%")` (lowercase pattern) matches no name (all are
        # capitalized), while the `ilike` mutant matches Alice — a clean complement that proves the
        # swap live. SQLite can't run ILIKE and never offers the swap, so this is guarded off there.
        test "flipping like to ilike matches the capitalized name the case-sensitive form missed" do
          if H.postgres?(@repo) do
            {mod, sites} =
              H.compile(
                """
                defmodule Q do
                  import Ecto.Query
                  alias MyApp.User
                  def q, do: from(u in User, where: like(u.name, "a%"), select: u.id)
                end
                """,
                repo: @repo,
                mutators: [{Mutare.Ecto, repo: @repo, dialects: [:postgres]}]
              )

            {baseline, mutant} =
              observe_ids(mod, sites, {~s|like(u.name, "a%")|, ~s|ilike(u.name, "a%")|})

            # Case-sensitive `like` against a lowercase pattern: no capitalized name matches.
            assert baseline == []
            # Case-insensitive `ilike` admits Alice.
            assert mutant == [1]
          end
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

          {baseline, mutant} =
            observe_ids(mod, sites, {"u.age + u.score > 100", "u.age - u.score > 100"})

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

          {baseline, mutant} = observe_ids(mod, sites, {"u.age * 2 > 40", "u.age / 2 > 40"})

          # Baseline: ages over 20 — Bob (25), Eve (40).
          assert baseline == [2, 5]
          # `/ 2 > 40` needs age > 80 — no row qualifies.
          assert mutant == []
        end
      end

      describe "Temporal — `ago` ↔ `from_now` (dynamic-injected)" do
        # `joined_at > ago(1, "day")` keeps the row seeded a minute ago (Frank); the flip re-asks the
        # comparison against tomorrow's instant, which nothing clears. Only a row *between* the two
        # instants distinguishes them — exactly what Frank is seeded to be.
        test "flipping the time direction empties the recent-rows window" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, where: u.joined_at > ago(1, "day"), select: u.id)
            end
            """)

          {baseline, mutant} =
            observe_ids(
              mod,
              sites,
              {~s|u.joined_at > ago(1, "day")|, ~s|u.joined_at > from_now(1, "day")|}
            )

          # Frank joined a minute ago; everyone else ten days back.
          assert baseline == [6]
          # Nothing is newer than tomorrow.
          assert mutant == []
        end
      end

      describe "Coalesce — drop the NULL fallback in a `where` (dynamic-injected)" do
        # `coalesce(u.score, 100) > 60` admits the NULL-score rows through the default; the drop
        # (`u.score > 60`) excludes them (NULL compares unknown). The difference is exactly the rows
        # the default exists for — if the injected dynamic were inert, the mutant would keep them.
        test "without the default the NULL-score rows fall out" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, where: coalesce(u.score, 100) > 60, select: u.id)
            end
            """)

          {baseline, mutant} =
            observe_ids(mod, sites, {"coalesce(u.score, 100) > 60", "u.score > 60"})

          # Alice (100), Bob (NULL → 100), Dave (NULL → 100), Frank (70); Carol 50 / Eve 0 miss.
          assert baseline == [1, 2, 4, 6]
          # Dropping the default excludes the NULL scores: Alice and Frank remain.
          assert mutant == [1, 6]
        end
      end

      describe "Coalesce — drop the fallback in a `select` (whole-`from`)" do
        # The in-place twin: a `select` coalesce is rewritten as a whole-`from` mutant
        # (`Mutare.Ecto.Scalar` via `Mutare.Ecto.Query`), so the selected value itself goes NULL.
        test "the selected default becomes NULL for the NULL-score row" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, where: u.id == 2, select: coalesce(u.score, 0))
            end
            """)

          {baseline, drop} =
            observe_rows(mod, sites, {~r/coalesce\(u\.score, 0\)/, ~r/\Au\.score\z/})

          # Bob's score is NULL, so the baseline selects the default…
          assert baseline == [0]
          # …and the drop selects the raw NULL.
          assert drop == [nil]
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

          {baseline, mutant} =
            observe_ids(mod, sites, {~r/where\(\[a, b\]/, ~r/where\(\[b, a\]/})

          # [a, b] with a.views>b.views over a.id<b.id pairs: (1,3) 10>5, (2,3) 20>5.
          assert baseline == [{1, 3}, {2, 3}]
          # Swapped to [b, a] (a now binds the join side, b the source): only (1,2) 20>10.
          assert mutant == [{1, 2}]
        end
      end

      describe "filter-drop — remove a `where` clause (whole-`from`)" do
        # "Is this filter tested?" Dropping the whole `where: u.age > 18` clause widens the result to the
        # entire table. The drop is now reported (as a deletion) at the condition itself, so it's the
        # lone site whose mutated half is empty — located with the same one-and-only-one `site_by`
        # guard, so a sibling comparison/boundary mutant of the same condition can't be mistaken for it.
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
              &(&1.original_code =~ "u.age > 18" and &1.mutated_code == "")
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

          {baseline, dropped} = observe_ids(mod, sites, {~r/where\(/, ~r/identity/})

          # Baseline: ages strictly over 18 — Bob(25), Eve(40), Frank(19).
          assert baseline == [2, 5, 6]
          # With the filter stage dropped, every row survives.
          assert dropped == [1, 2, 3, 4, 5, 6]
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

          {baseline, flipped} = observe_rows(mod, sites, {~r/asc: u.age/, ~r/desc: u.age/})

          # Ascending, the youngest (Carol, 17) tops; descending, the oldest (Eve, 40).
          assert baseline == [3]
          assert flipped == [5]
        end
      end

      describe "OrderingNulls — `asc_nulls_first` ↔ `asc_nulls_last` (whole-`from`)" do
        # The equivalence-sensitive NULLs-placement axis, live against real NULL rows (SQLite has
        # supported NULLS FIRST/LAST since 3.30). Bob and Dave carry NULL scores; the flip moves
        # exactly them across the ordering while the non-NULL order is untouched. Their order
        # *within* the NULL group is engine-unspecified, so the test pins the group's position and
        # membership, never the intra-group order.
        test "the nulls_last mutant moves the NULL-score rows from the front to the back" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, order_by: [asc_nulls_first: u.score], select: u.id)
            end
            """)

          {baseline, mutant} = observe_rows(mod, sites, {~r/asc_nulls_first/, ~r/asc_nulls_last/})

          # Baseline: the NULL scores (Bob 2, Dave 4) lead, then 0 (Eve), 50 (Carol), 70 (Frank), 100 (Alice).
          assert baseline |> Enum.take(2) |> Enum.sort() == [2, 4]
          assert Enum.drop(baseline, 2) == [5, 3, 6, 1]

          # Mutant: same non-NULL ascent, the NULL rows now trail.
          assert Enum.take(mutant, 4) == [5, 3, 6, 1]
          assert mutant |> Enum.drop(4) |> Enum.sort() == [2, 4]
        end
      end

      describe "Bound — drop (whole-`from`) / bump (pin-only weave) of `limit`" do
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

          # The bump is woven pin-only (`limit: ^(case …)`), so its recorded diff is the bare
          # integer pair — the only site whose original is exactly "2".
          bump = site_id(sites, {"2", "3"})

          assert ids(mod, bump) == [1, 2, 3]

          # The −1 bump is a distinct live branch of the same weave, under its own id.
          assert ids(mod, site_id(sites, {"2", "1"})) == [1]

          # The drop is now reported (as a deletion) at the bound value, so it's the lone site whose
          # original is exactly "2" and whose mutated half is empty — distinct from the ±1 bumps of the
          # same value. `site_by` gives this the same one-and-only-one guard as `site_id`.
          drop =
            site_by(
              sites,
              "limit-drop",
              &(&1.original_code == "2" and &1.mutated_code == "")
            )

          assert ids(mod, drop.id) == [1, 2, 3, 4, 5, 6]
        end
      end

      describe "Bound — drop (whole-`from`) / bump (pin-only weave) of `offset`" do
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

          # offset 3 skips one more from the top. The bump's pin-only diff is the bare integer pair;
          # "2" is unambiguous here (the limit's bumps anchor on "10").
          bump = site_id(sites, {"2", "3"})

          assert ids(mod, bump) == [4, 5, 6]

          # The drop is now reported (as a deletion) at the bound value: the lone site whose original is
          # exactly "2" (the offset — the limit's bumps/drop anchor on "10") and whose mutated half is
          # empty, distinct from the offset's own ±1 bumps. Same one-and-only-one `site_by` guard as the
          # limit-drop case.
          drop =
            site_by(
              sites,
              "offset-drop",
              &(&1.original_code == "2" and &1.mutated_code == "")
            )

          assert ids(mod, drop.id) == [1, 2, 3, 4, 5, 6]
        end
      end

      describe "Bound — bump of a standalone/pipe stage (pin-only weave)" do
        # The pipe form splices through a different transform than the from-keyword form
        # (`Target.bound_argument` / `QueryCall.replace_arg`, not the clause-list replacement), so
        # its weave needs its own liveness proof: an inert splice — one that recorded a perfect Site
        # but bound the baseline integer on every branch — would pass every unit test.
        test "bumping a piped limit widens the window against the engine" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: User |> order_by(asc: :id) |> limit(2) |> select([u], u.id)
            end
            """)

          {baseline, mutant} = observe_ids(mod, sites, {"2", "3"})

          assert baseline == [1, 2]
          assert mutant == [1, 2, 3]

          # Both branches of the woven selector are live, each under its own id.
          assert ids(mod, site_id(sites, {"2", "1"})) == [1]
        end
      end

      describe "JoinType — left → inner (whole-`from`, narrowing)" do
        # Cardinality change: a LEFT join keeps the orphan post (user_id 99 matches no user); the INNER
        # mutant drops it. This is the direction the plugin actually offers — see `Mutare.Ecto.Query`'s
        # moduledoc for why the reverse (widening inner to left) is deliberately not: a strong,
        # killable mutation that must hit the DB to show.
        test "the inner-join mutant drops the orphan row the left join keeps" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.{Post, User}
              def q do
                from p in Post, left_join: u in User, on: u.id == p.user_id, select: p.id
              end
            end
            """)

          {baseline, mutant} =
            observe_ids(mod, sites, {~r/left_join:/, ~r/inner_join:/})

          # Left join: the matched posts plus the orphan P3 (user_id 99).
          assert baseline == [1, 2, 3]
          # Inner join narrows away the orphan.
          assert mutant == [1, 2]
        end
      end

      describe "JoinType — full → left (whole-`from`, narrowing, portable)" do
        # `full_join`→`left_join` targets a universally portable kind, so it needs no `dialects:` gate
        # (unlike the never-offered widening direction, or `full_join`→`right_join`, gated by
        # `@right_join_dialects` and covered only at the config layer — SQLite can't run RIGHT JOIN, so
        # there's no live proof for it here). LEFT keeps the orphan post (user_id 99) but drops the
        # four post-less users that FULL would have kept on the right side.
        test "the left-join mutant drops the post-less users the full join keeps" do
          # Runtime-guarded rather than tag-skipped: the CI matrix pins the adapter (and its bundled
          # SQLite) per Ecto line, and a SQLite below 3.39 rejects FULL JOIN at query time — which
          # would be an engine limitation, not a delivery failure. Postgres always supports it.
          if H.full_join_supported?(@repo) do
            {mod, sites} =
              build("""
              defmodule Q do
                import Ecto.Query
                alias MyApp.{Post, User}
                def q do
                  from p in Post, full_join: u in User, on: u.id == p.user_id, select: {p.id, u.id}
                end
              end
              """)

            {baseline, mutant} =
              observe_ids(mod, sites, {~r/full_join:/, ~r/left_join:/})

            # Full join: the matched pairs, the orphan post (P3 → no user), and the four post-less users.
            assert baseline == [{1, 1}, {2, 2}, {3, nil}, {nil, 3}, {nil, 4}, {nil, 5}, {nil, 6}]
            # Left join narrows away the post-less users, keeping only the left-preserved rows.
            assert mutant == [{1, 1}, {2, 2}, {3, nil}]
          end
        end
      end

      describe "JoinType — left → right (dialect-only, Postgres/MySQL)" do
        # The RIGHT-join arm the `full → left` test notes is covered only at the config layer on
        # SQLite: `left_join`→`right_join` swaps which side is preserved. Gated by `dialects:
        # [:postgres]` (the plugin never offers it otherwise) and by the Postgres runtime (SQLite
        # below 3.39 can't run RIGHT JOIN at all). LEFT preserves the posts (keeping orphan P3);
        # RIGHT preserves the users (keeping the four post-less users, dropping the orphan post).
        test "the right-join mutant preserves the users instead of the posts" do
          if H.postgres?(@repo) do
            {mod, sites} =
              H.compile(
                """
                defmodule Q do
                  import Ecto.Query
                  alias MyApp.{Post, User}
                  def q do
                    from p in Post, left_join: u in User, on: u.id == p.user_id, select: {p.id, u.id}
                  end
                end
                """,
                repo: @repo,
                mutators: [
                  {Mutare.Ecto, repo: @repo, families: [:join_type], dialects: [:postgres]}
                ]
              )

            {baseline, mutant} =
              observe_ids(mod, sites, {~r/left_join:/, ~r/right_join:/})

            # Left join: the matched pairs plus the orphan post P3 (user_id 99 → no user).
            assert baseline == [{1, 1}, {2, 2}, {3, nil}]
            # Right join preserves the users: the matched pairs plus the four post-less users, and
            # the orphan post is dropped (its side is no longer preserved).
            assert mutant == [{1, 1}, {2, 2}, {nil, 3}, {nil, 4}, {nil, 5}, {nil, 6}]
          end
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

          {baseline, mutant} =
            observe_ids(mod, sites, {~r/intersect:/, ~r/except:/})

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

          {baseline, mutant} =
            observe_ids(mod, sites, {~r/intersect\(\^adults\)/, ~r/except\(\^adults\)/})

          assert baseline == [2, 5, 6]
          assert mutant == [1]
        end
      end

      describe "Combination — `intersect_all` ↔ `except_all` (dialect-only, Postgres/MySQL)" do
        # The duplicate-preserving `_all` set-ops SQLite can't execute (covered only at the config
        # layer there). The plugin emits the swap on any dialect, so no `dialects:` gate is needed —
        # only the Postgres runtime guard. With no duplicate ids across the two sides, `INTERSECT
        # ALL`/`EXCEPT ALL` partition exactly like their plain twins: active ∩ adults vs active ∖
        # adults, so the swap flips to the other side of the partition.
        test "swapping intersect_all for except_all returns the left-only rows instead of the shared" do
          if H.postgres?(@repo) do
            {mod, sites} =
              H.compile(
                """
                defmodule Q do
                  import Ecto.Query
                  alias MyApp.User

                  def q do
                    adults = from(u in User, where: u.age > 18, select: u.id)
                    from(u in User, where: u.active, select: u.id, intersect_all: ^adults)
                  end
                end
                """,
                repo: @repo,
                mutators: [{Mutare.Ecto, repo: @repo, families: [:combination]}]
              )

            {baseline, mutant} =
              observe_ids(mod, sites, {~r/intersect_all:/, ~r/except_all:/})

            # active ∩ adults: Bob, Eve, Frank.
            assert baseline == [2, 5, 6]
            # active ∖ adults: only Alice (active but sitting on the age-18 boundary).
            assert mutant == [1]
          end
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

      describe "Join `on:` — a hosted condition of a standalone join (keyword-option weave)" do
        # The one splice shape without a liveness proof until now: a standalone/pipe join's sole
        # `on:` option is woven through `Target.keyword_condition` (the selector spliced *inside*
        # the trailing keyword list), a different transform than the from-clause and condition
        # weaves proven above. The nearby assoc-join test observes only the baseline.
        test "the >= mutant of the on-condition admits the boundary post" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.{Post, User}

              def q do
                User
                |> where([u], u.id == 1)
                |> join(:inner, [u], p in Post, on: p.views > 10)
                |> select([u, p], p.id)
              end
            end
            """)

          {baseline, mutant} = observe_ids(mod, sites, {"p.views > 10", "p.views >= 10"})

          # Baseline: user 1 joined to the posts with views strictly over 10 — only P2 (20).
          assert baseline == [2]
          # The `>=` mutant admits the boundary post P1 (views 10) into the join.
          assert mutant == [1, 2]
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

          {[sum], [avg]} = observe_rows(mod, sites, {~r/sum\(u\.age\)/, ~r/avg\(u\.age\)/})

          # Σ ages over the six users.
          assert sum == 18 + 25 + 17 + 18 + 40 + 19

          # avg = sum / 6 — a different value, and not the integer sum. `avg` is adapter-typed (a float
          # on SQLite, a Decimal on Postgres), so normalize it before the numeric delta.
          assert avg != sum
          assert_in_delta to_number(avg), sum / 6, 0.001
        end
      end

      describe "Arithmetic — `+` ↔ `-` in `select` (whole-`from`)" do
        # The in-place twin of the hosted arithmetic swap: an operator inside a `select` value is
        # rewritten as a whole-`from` mutant (`Mutare.Ecto.Scalar` via `Mutare.Ecto.Query`), so the
        # risk here is a rewrite that renders but never reaches the engine.
        test "swapping the select's sum to a difference returns a different computed value" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, where: u.id == 1, select: u.age + u.score)
            end
            """)

          {[total], [difference]} =
            observe_rows(
              mod,
              sites,
              {~r/u\.age \+ u\.score/, ~r/u\.age - u\.score/}
            )

          # Alice: 18 + 100.
          assert total == 118
          # The `-` mutant computes 18 - 100 over the same row.
          assert difference == -82
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

          {baseline, mutant} = observe_ids(mod, sites, {"sum(u.age) > 25", "avg(u.age) > 25"})

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
          alias MyApp.Account
          alias #{inspect(@repo)}, as: Repo

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
              mutators: [{Mutare.Ecto, repo: @repo, families: [:on_conflict]}]
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
          alias MyApp.Account
          alias #{inspect(@repo)}, as: Repo

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
              mutators: [{Mutare.Ecto, repo: @repo, families: [:on_conflict]}]
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

      describe "RepoAggregate — `Repo.aggregate(q, :sum, :age)` → `:avg` (Repo call, value-observed)" do
        # A Bucket-1 plain-call family: no query weave, the aggregate *atom* is swapped in the call.
        # Observed through the computed value — the sum of the six ages vs their average — so an
        # unswapped atom (a dead in-place selector) fails on the exact number.
        test "the :avg mutant computes the average where the baseline sums" do
          {mod, sites} =
            build("""
            defmodule Q do
              alias MyApp.User
              alias #{inspect(@repo)}, as: Repo
              def total, do: Repo.aggregate(User, :sum, :age)
            end
            """)

          swap = site_id(sites, {~r/:sum/, ~r/:avg/})

          # Baseline: 18 + 25 + 17 + 18 + 40 + 19.
          assert H.activate(0, fn -> mod.total() end) == 137

          # Mutant: the same column's average (adapter-typed — float on SQLite, Decimal elsewhere).
          assert_in_delta to_number(H.activate(swap, fn -> mod.total() end)), 137 / 6, 0.001
        end
      end

      describe "QueryTerminal — `first` ↔ `last` (plain Ecto.Query function)" do
        # `first(q, :age)` orders ascending and takes one row; the `last` mutant reverses the order.
        # Ages 17 (Carol) and 40 (Eve) are unique at both edges, so each side pins one exact row.
        test "the last mutant returns the opposite edge of the ordering" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              alias #{inspect(@repo)}, as: Repo
              def edge, do: Repo.one(first(User, :age))
            end
            """)

          swap = site_id(sites, {~r/first\(User/, ~r/last\(User/})

          assert H.activate(0, fn -> mod.edge() end).id == 3
          assert H.activate(swap, fn -> mod.edge() end).id == 5
        end
      end

      describe "Persistence — `Repo.insert` → `apply_action` (Repo write, absence-observed)" do
        # The headline write mutation: the mutant preserves the `{:ok, struct}` shape while skipping
        # the write entirely, so it is killed only by asserting a *persistence consequence*. Both
        # halves observed: the baseline assigns an id and leaves a row; the mutant returns ok with a
        # nil id and leaves no row.
        @insert_src """
        defmodule W do
          alias MyApp.Account
          alias #{inspect(@repo)}, as: Repo
          def create, do: Repo.insert(%Account{email: "new@x", name: "Fresh"})
        end
        """

        test "the apply_action mutant returns {:ok, _} without writing the row" do
          {mod, sites} =
            H.compile(@insert_src,
              mutators: [{Mutare.Ecto, repo: @repo, families: [:persistence]}]
            )

          swap = site_id(sites, {~r/Repo\.insert/, ~r/apply_action/})

          # Baseline: a real INSERT — id assigned, row present.
          reset_accounts!()
          assert {:ok, %MyApp.Account{id: id}} = H.activate(0, fn -> mod.create() end)
          assert is_integer(id)
          assert %MyApp.Account{name: "Fresh"} = account("new@x")

          # Mutant: the same ok-shaped result, but nothing reached the table.
          reset_accounts!()
          assert {:ok, %MyApp.Account{id: nil}} = H.activate(swap, fn -> mod.create() end)
          refute account("new@x")
        end
      end

      describe "ValidationDrop — a dropped `validate_required` admits the write it rejected" do
        # The changeset stage drop, observed through the write it gates: with `:name` missing the
        # baseline pipeline returns `{:error, changeset}` and inserts nothing; the mutant (validator
        # stage dropped to identity) passes the changeset through valid and the insert lands.
        @validated_src """
        defmodule W do
          import Ecto.Changeset
          alias MyApp.Account
          alias #{inspect(@repo)}, as: Repo

          def create(attrs) do
            %Account{}
            |> cast(attrs, [:email, :name])
            |> validate_required([:name])
            |> Repo.insert()
          end
        end
        """

        test "the dropped validator lets an invalid insert through" do
          {mod, sites} =
            H.compile(@validated_src,
              mutators: [{Mutare.Ecto, repo: @repo, families: [:validation_drop]}]
            )

          drop = site_id(sites, {~r/validate_required/, ~r/identity/})
          attrs = %{"email" => "v@x"}

          # Baseline: the validator rejects the nameless changeset — no row.
          reset_accounts!()

          assert {:error, %Ecto.Changeset{valid?: false}} =
                   H.activate(0, fn -> mod.create(attrs) end)

          refute account("v@x")

          # Mutant: the pipeline no longer validates — the insert succeeds and the row lands.
          reset_accounts!()
          assert {:ok, %MyApp.Account{}} = H.activate(drop, fn -> mod.create(attrs) end)
          assert %MyApp.Account{name: nil} = account("v@x")
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

          @repo.all(
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

          @repo.all(from([..., c] in base, where: c.age > 18, select: c.id))
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

          @repo.all(
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

      describe "Exotic constructs — a CTE interior mutant is live" do
        # The CTE's interior is an ordinary query mutated where it is *built*; this proves the woven
        # `dynamic` still runs when that query is then attached as a `WITH` and joined through its
        # name — the whole CTE plumbing (recursive machinery aside) between the mutant and the rows.
        test "the >= mutant inside the CTE admits the boundary post the > baseline excludes" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.Post

              def q do
                popular = from(p in Post, where: p.views > 10, select: %{id: p.id})

                Post
                |> with_cte("popular", as: ^popular)
                |> join(:inner, [p], c in "popular", on: c.id == p.id)
                |> select([p, c], p.id)
              end
            end
            """)

          {baseline, mutant} = observe_ids(mod, sites, {"p.views > 10", "p.views >= 10"})

          # Baseline CTE keeps views strictly over 10 — only P2(20); the join filters posts to it.
          assert baseline == [2]
          # The `>=` mutant admits the boundary P1(10) into the CTE, and the join follows.
          assert mutant == [1, 2]
        end
      end

      describe "Exotic constructs — a window-function aggregate swap is live" do
        # The sum↔avg swap inside an inline `over/2` is a whole-`from` rewrite; the mutant query
        # computes a different number per partition, proving the swap survives the window syntax.
        test "the avg mutant computes a different partition total than the sum baseline" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.Post

              def q do
                from p in Post,
                  order_by: p.id,
                  select: {p.id, over(sum(p.views), partition_by: p.published)}
              end
            end
            """)

          {baseline, mutant} =
            observe_rows(mod, sites, {~r/over\(sum\(p\.views\)/, ~r/over\(avg\(p\.views\)/})

          # Partitions: published {P1(10), P3(5)} and unpublished {P2(20)}. The avg mutant's per-partition
          # value is adapter-typed (float on SQLite, Decimal on Postgres), so normalize before comparing.
          assert baseline == [{1, 15}, {2, 20}, {3, 15}]

          assert Enum.map(mutant, fn {id, value} -> {id, to_number(value)} end) ==
                   [{1, 7.5}, {2, 20.0}, {3, 7.5}]
        end
      end

      describe "Exotic constructs — a composed-dynamic connective swap is live" do
        # `dynamic([u], ^d1 and ^d2)` is rebuilt whole (an in-place rewrite, not a weave); flipping
        # the id must change which *composition* the interpolated where receives at runtime.
        test "the or mutant admits rows satisfying either leaf where and required both" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User

              def q do
                d1 = dynamic([u], u.active == true)
                d2 = dynamic([u], u.age > 18)
                combined = dynamic([u], ^d1 and ^d2)
                from u in User, where: ^combined, select: u.id
              end
            end
            """)

          {baseline, mutant} =
            observe_ids(mod, sites, {"dynamic([u], ^d1 and ^d2)", "dynamic([u], ^d1 or ^d2)"})

          # and: active AND over 18 — Bob(2), Eve(5), Frank(6). Alice is active but on the boundary.
          assert baseline == [2, 5, 6]

          # or: additionally Alice (active, 18). Carol/Dave are inactive and not over 18 either way.
          assert mutant == [1, 2, 5, 6]
        end
      end

      describe "Exotic constructs — a filtered-aggregate condition mutant is live" do
        # `filter(count(...), cond)` in a having: the woven dynamic carries the FILTER clause; the
        # mutant relaxes the inner condition and a group crosses the having threshold.
        test "the >= mutant inside filter/2 lifts the published group over the having bar" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.Post

              def q do
                from p in Post,
                  group_by: p.published,
                  having: filter(count(p.id), p.views > 5) > 1,
                  select: p.published
              end
            end
            """)

          {baseline, mutant} =
            observe_ids(
              mod,
              sites,
              {"filter(count(p.id), p.views > 5) > 1", "filter(count(p.id), p.views >= 5) > 1"}
            )

          # Per published-group counts of views > 5: {P1} and {P2} — one each, no group passes.
          assert baseline == []
          # views >= 5 admits P3(5) into the published group's count (2 > 1) — it now passes.
          assert mutant == [true]
        end
      end

      describe "Exotic constructs — a hosted mutant inside an update_all query is live" do
        # The where of an update query is hosted exactly like a select query's; the observation is
        # the write: the baseline updates the account row, the `!=` mutant updates everything but it.
        test "the != mutant redirects the update away from the matched row" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.Account

              def q do
                #{inspect(@repo)}.update_all(
                  from(a in Account, where: a.email == "a@x", update: [set: [name: "Bumped"]]),
                  []
                )
              end
            end
            """)

          id = site_id(sites, {~s|a.email == "a@x"|, ~s|a.email != "a@x"|})

          reset_accounts!()
          H.activate(0, fn -> apply(mod, :q, []) end)
          assert account_name() == "Bumped"

          reset_accounts!()
          H.activate(id, fn -> apply(mod, :q, []) end)
          assert account_name() == "Original"
        end
      end

      # =======================================================================
      # Reverse-direction liveness. Every swap family elsewhere in this file is
      # proven in ONE direction. Each reverse is a *distinct* selector branch
      # under its own mutant id, so its delivery is a separate claim — a catalog
      # bug that broke only the reverse arm would pass every forward test. These
      # flip the sibling branch (the emphasis is the equivalence-sensitive
      # families, where a one-armed break is the most dangerous).
      # =======================================================================

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

      describe "NullPredicate — `not is_nil` → `is_nil` (reverse arm of the null flip)" do
        # A catalog bug that broke only the reverse arm would pass the forward `is_nil` → `not is_nil`
        # test — so pin the reverse selector branch directly, as the section does for the others.
        test "flipping not-null back to is_nil returns exactly the null-score rows" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, where: not is_nil(u.score), select: u.id)
            end
            """)

          {baseline, mutant} =
            observe_ids(mod, sites, {"not is_nil(u.score)", "is_nil(u.score)"})

          # not-null scores: everyone but Bob/Dave.
          assert baseline == [1, 3, 5, 6]
          # the reverse arm keeps exactly the null-score rows — the complement.
          assert mutant == [2, 4]
        end
      end

      describe "Temporal — `from_now` → `ago` (reverse arm of the direction flip)" do
        # The mirror of the forward `ago` → `from_now` test: written the other way round, a
        # reverse-only catalog break would slip past the forward arm.
        test "flipping the future window back to the past re-admits the recent row" do
          {mod, sites} =
            build("""
            defmodule Q do
              import Ecto.Query
              alias MyApp.User
              def q, do: from(u in User, where: u.joined_at > from_now(1, "day"), select: u.id)
            end
            """)

          {baseline, mutant} =
            observe_ids(
              mod,
              sites,
              {~s|u.joined_at > from_now(1, "day")|, ~s|u.joined_at > ago(1, "day")|}
            )

          # Nothing is timestamped in the future, so the from_now window is empty.
          assert baseline == []
          # Flipping to ago re-admits Frank (joined a minute ago).
          assert mutant == [6]
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

          {baseline, flipped} = observe_rows(mod, sites, {~r/desc: u.age/, ~r/asc: u.age/})

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
              alias MyApp.User
              alias #{inspect(@repo)}, as: Repo
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

      # =======================================================================
      # Dark families — families the rest of the file exercises only
      # structurally (catalog/compile), now proven live: the untested
      # aggregate/combination arms and the opt-in literal arms and the deferred
      # changeset hook drop.
      # =======================================================================

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
              mutators: [{Mutare.Ecto, repo: @repo, families: [:boolean_literal]}]
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
              mutators: [{Mutare.Ecto, repo: @repo, families: [:string_literal]}]
            )

          {baseline, mutant} = observe_ids(mod, sites, {~s|u.role == "admin"|, ~s|u.role == ""|})

          # role == "admin": Alice, Eve.
          assert baseline == [1, 5]
          # role == "": no user has an empty role, so the mutant matches nothing.
          assert mutant == []
        end
      end

      describe "AtomLiteral — an enum atom collapses to the invalid `:mutare` sentinel (opt-in arm)" do
        # `u.status == :active` compares an `Ecto.Enum` field to a bare atom literal — the one place
        # a literal atom is valid, result-affecting Ecto (a string column rejects an atom outright).
        # The AtomLiteral arm rewrites `:active` to the `:mutare` sentinel, which is not a member of
        # the enum, so the woven query *raises* when it runs — proving the atom reached SQL (an inert
        # delivery would return the baseline rows, not raise). The raise-observed twin of the
        # on_conflict `:nothing → :raise` test, and the only liveness proof for an atom that (unlike
        # a string/int/bool literal) can never flip a row set — every non-member value raises.
        test "the mutated atom is delivered — the invalid enum member makes the query raise" do
          {mod, sites} =
            H.compile(
              """
              defmodule Q do
                import Ecto.Query
                alias MyApp.User
                def q, do: from(u in User, where: u.status == :active, select: u.id)
              end
              """,
              mutators: [{Mutare.Ecto, repo: @repo, families: [:atom_literal]}]
            )

          id = site_id(sites, {"u.status == :active", "u.status == :mutare"})

          # Baseline: the active-status users — a non-empty, correct row set, so the mutant's raise
          # is a genuine behavior change, not an already-broken query.
          assert ids(mod, 0) == [1, 2, 5, 6]

          # Mutant: `:mutare` is not a valid `status`, so the injected `dynamic` raises when the
          # query is built and run. An inert delivery would instead return the baseline ids.
          assert raises?(fn -> q_under(mod, id) end)
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
              mutators: [{Mutare.Ecto, repo: @repo, families: [:float_literal]}]
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
          alias MyApp.Account
          alias #{inspect(@repo)}, as: Repo

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
              mutators: [{Mutare.Ecto, repo: @repo, families: [:hook_drop]}]
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
  end
end
