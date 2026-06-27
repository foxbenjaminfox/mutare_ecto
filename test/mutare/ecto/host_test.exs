defmodule Mutare.Ecto.HostTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport
  alias Mutare.Ecto.Host

  # The localized `where`/`having` mutations the selector host delivers via Ecto's `^`/`dynamic`
  # injection. These tests prove three things end to end: the right call positions route `:hosted`,
  # the woven `dynamic` re-declares the correct binding list, and the rendered metamutant compiles.
  # The SQL catalog itself (which operators swap) is `Mutare.Ecto.Fragment`'s job and tested there;
  # here we only confirm a catalog hit is *delivered* correctly.

  # The host's `{original, mutated}` diffs — recorded from the *logical* pair (the bare condition),
  # so, unlike the whole-`from` query mutations, they never mention `from(`. That's the discriminator.
  defp hosted(source) do
    source
    |> ecto_diffs()
    |> Enum.reject(fn {original, _mutated} -> String.starts_with?(original, "from(") end)
  end

  describe "binding extraction — the dynamic wrap" do
    test "a single-binding from re-declares [u] in the woven dynamic" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.age > 18, select: u.id)
      end
      """

      mm = metamutant(src)
      assert mm =~ "dynamic([u]"
      refute mm =~ "dynamic([u,"
      assert_compiles(src)
    end

    test "a join accumulates bindings: dynamic re-declares [u, p] for a join-referencing where" do
      # The highest-value case: the woven `dynamic` must re-declare *every* positional binding the
      # query establishes (source + each join), in order — or the mutant fragment won't compile.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            join: p in Post,
            on: p.user_id == u.id,
            where: p.views > 1,
            select: u.id
        end
      end
      """

      assert Enum.any?(hosted(src), fn {original, _mutated} -> original == "p.views > 1" end)
      assert metamutant(src) =~ "dynamic([u, p]"
      assert_compiles(src)
    end

    test "named source rebind + positional join anchors the join to the tail with `...`" do
      # Regression (BUG-from_bindings-named-rebind-join.md): a query that rebinds *named* sources up
      # front and adds a *positional* join after establishes its bindings at positions `[s@0, f@1, j@2]`
      # (named binds rebind by name; the join lands at the tail). The woven dynamic must (a) sort the
      # `{as, var}` named binds **last** (`dynamic/2` requires it) *and* (b) anchor the join with `...`,
      # or `j` re-binds to position 0 — a silently wrong baseline, not a compile error. The earlier
      # `[j, source: s, file: f]` shape compiled but corrupted the SQL (it mapped `j` to `s`'s
      # position), which `assert_compiles` alone could never catch; the semantic suite proves the fix.
      src = """
      defmodule M do
        import Ecto.Query
        def q(base) do
          from [source: s, file: f] in base,
            inner_join: j in Post,
            on: j.source_id == s.id,
            where: j.hash == f.hash,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([..., j, source: s, file: f]"
      assert_compiles(src)
    end

    test "a mixed source pattern (positional + named) keeps the positional in front, anchors the join" do
      # `[a, post: p] in base` contributes a leading positional (`a`, rebinding position 0) *and* a
      # named rebind (`p`). The named rebind makes `base`'s positions past `a` opaque, so the join is
      # still `...`-anchored: `[a, ..., j, post: p]` — leading positional in front, join behind `...`,
      # named last. (Distinguishes the two arms of the anchor rule: a leading positional alone would
      # *not* anchor, but the named rebind forces it.)
      src = """
      defmodule M do
        import Ecto.Query
        def q(base) do
          from [a, post: p] in base,
            inner_join: j in Post,
            on: j.user_id == a.id,
            where: j.views > p.views,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([a, ..., j, post: p]"
      assert_compiles(src)
    end

    test "a positional-only source with a join stays contiguous (no `...`)" do
      # The counterpart: an all-positional rebind `[a, b] in base` pins positions 0/1, so the join
      # follows contiguously at position 2 — no anchor, `[a, b, j]` unchanged. Guards against
      # over-eagerly anchoring every join.
      src = """
      defmodule M do
        import Ecto.Query
        def q(base) do
          from [a, b] in base,
            inner_join: j in Post,
            on: j.user_id == a.id,
            where: j.views > b.views,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([a, b, j]"
      refute metamutant(src) =~ "dynamic([a, b, ..."
      assert_compiles(src)
    end

    test "an explicit `...` in a from source rebind is preserved" do
      # `[..., c] in query` declares `c` as the query's *last* binding. Dropping the `...` (the old
      # behavior) re-binds `c` to position 0 — the same baseline-corruption class as the named-rebind
      # bug, reached here via an anchor the source pattern wrote itself.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([..., c] in query, where: c.age > 1, select: c.id)
      end
      """

      assert metamutant(src) =~ "dynamic([..., c]"
      assert_compiles(src)
    end

    test "an explicit source `...` plus a join keeps both at the tail (no second anchor)" do
      # The source's own `...` already anchors the tail, so the join follows `c` contiguously
      # (`[..., c, j]`) — the host must not add a *second* `...`.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from [..., c] in query,
            inner_join: j in Post,
            on: j.user_id == c.id,
            where: j.views > c.id,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([..., c, j]"
      refute metamutant(src) =~ "dynamic([..., ..."
      assert_compiles(src)
    end

    test "a leading positional before a source `...` is preserved (`[a, ..., c]`)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([a, ..., c] in query, where: a.age > c.age, select: a.id)
      end
      """

      assert metamutant(src) =~ "dynamic([a, ..., c]"
      assert_compiles(src)
    end

    test "a named source with no join gets no spurious `...`" do
      # A named rebind alone (no join) re-declares exactly `[post: p]`; the host must not anchor a
      # tail that isn't there. (Pins the `join_positional != []` guard: with no join, no `...`.)
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([post: p] in query, where: p.title == "x", select: p.id)
      end
      """

      assert metamutant(src) =~ "dynamic([post: p]"
      refute metamutant(src) =~ "dynamic([..., post: p]"
      assert_compiles(src)
    end

    test "an opaque source with no positional binding anchors the join to the tail" do
      # `[] in query` rebinds none of `query`'s (unknown) bindings, so a join is appended after all of
      # them and must be `...`-anchored — `[..., j]`, not `[j]`. (Pins the `source_positional == []`
      # arm of the anchor: an empty source pattern is opaque, so the join still needs the anchor.)
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from [] in query,
            inner_join: j in Post,
            on: j.user_id == 1,
            where: j.views > 1,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([..., j]"
      assert_compiles(src)
    end

    test "a source `...` with named binds keeps a single anchor (no second `...`)" do
      # `[a, ..., post: p]` already anchors the tail itself, so the join follows `a` after the source's
      # own `...` — `[a, ..., j, post: p]`. Re-anchoring here would emit a second `...` (invalid Ecto).
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from [a, ..., post: p] in query,
            inner_join: j in Post,
            on: j.user_id == a.id,
            where: j.views > p.views,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([a, ..., j, post: p]"
      refute metamutant(src) =~ "dynamic([a, ..., ..."
      assert_compiles(src)
    end

    test "the standalone form recognizes a `...` binding list and hosts its condition" do
      # Previously `[..., c]` wasn't recognized as a binding list, so the condition was silently *not*
      # hosted (a missed mutation). It now hosts, re-declaring the `...` in the woven dynamic.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [..., c], c.age > 1)
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "c.age > 1" and mutated == "c.age >= 1"
             end)

      assert metamutant(src) =~ "dynamic([..., c]"
      assert_compiles(src)
    end

    test "the standalone form preserves an interior `...` (`[a, ..., b]`) in the woven dynamic" do
      # The anchor can sit *between* positionals — `a` rebinds the first source, `b` the last. The
      # woven dynamic must re-declare it verbatim (`[a, ..., b]`); collapsing or dropping it would
      # re-map `b` off the tail, corrupting the baseline the host weaves the mutant behind.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [a, ..., b], a.age > b.age)
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "a.age > b.age" and mutated == "a.age >= b.age"
             end)

      assert metamutant(src) =~ "dynamic([a, ..., b]"
      assert_compiles(src)
    end

    test "the pipe form re-declares its stage binding list" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> where([u], u.x == u.y)
      end
      """

      assert metamutant(src) =~ "dynamic([u]"
      assert_compiles(src)
    end

    test "the direct form re-declares its binding list" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [u], u.age > 18)
      end
      """

      assert metamutant(src) =~ "dynamic([u]"
      assert_compiles(src)
    end
  end

  describe "routing the condition family (from keyword form)" do
    for key <- ~w(where or_where having or_having)a do
      test "#{key} routes :hosted and yields a localized mutant" do
        key = unquote(key)

        src = """
        defmodule M do
          import Ecto.Query
          def q, do: from(u in User, #{key}: u.x == u.y, select: u.id)
        end
        """

        # The localized swap is delivered (logical diff `==` → `!=`), invisible scaffolding.
        assert Enum.any?(hosted(src), fn {_original, mutated} -> mutated == "u.x != u.y" end)
        assert metamutant(src) =~ "dynamic([u]"
        assert_compiles(src)
      end
    end
  end

  describe "standalone + pipe macros" do
    test "pipe where hosts the condition that follows the binding list" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> where([u], u.x == u.y)
      end
      """

      assert Enum.any?(hosted(src), fn {_original, mutated} -> mutated == "u.x != u.y" end)
      assert_compiles(src)
    end

    test "direct where(q, [u], cond) hosts the condition" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [u], u.x == u.y)
      end
      """

      assert Enum.any?(hosted(src), fn {_original, mutated} -> mutated == "u.x != u.y" end)
      assert_compiles(src)
    end

    test "direct having(q, [u], cond) hosts the condition" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: having(query, [u], u.x == u.y)
      end
      """

      assert Enum.any?(hosted(src), fn {_original, mutated} -> mutated == "u.x != u.y" end)
      assert_compiles(src)
    end
  end

  describe "nothing hostable" do
    test "a bindingless from carries no hosted dynamic (clauses are shorthand data)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from("users", where: [active: true], select: [:id])
      end
      """

      assert hosted(src) == []
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a keyword-shorthand where weaves no hosted dynamic (only the stage drop fires)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, active: true)
      end
      """

      # The host weaves nothing into a shorthand `where` (its value is core's job, `^`-pinned) — no
      # `dynamic(` scaffolding. The one mutation is the orthogonal stage drop (collapse to query).
      assert [{:ecto, original, "query"}] = diffs(src)
      assert original =~ "where(query"
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end
  end

  describe "the catalog families deliver through the host" do
    test "membership polarity (in / not in) is woven and compiles" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(roles), do: from(u in User, where: u.role in ^roles, select: u.id)
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "u.role in ^roles" and mutated == "u.role not in ^roles"
             end)

      assert metamutant(src) =~ "dynamic([u]"
      assert_compiles(src)
    end

    test "like/ilike is woven and compiles (Postgres dialect)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(pat), do: from(u in User, where: like(u.name, ^pat), select: u.id)
      end
      """

      pg = [mutators: [{Mutare.Ecto, repo: MyApp.Repo, dialects: [:postgres]}]]

      hosted_pg =
        src
        |> ecto_diffs(pg)
        |> Enum.reject(fn {original, _m} -> String.starts_with?(original, "from(") end)

      assert Enum.any?(hosted_pg, fn {_o, mutated} -> mutated == "ilike(u.name, ^pat)" end)
      assert_compiles(src, pg)
    end

    test "an in-fragment integer literal bump is woven and compiles" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: u.age > 18, select: u.id)
      end
      """

      mutated = Enum.map(hosted(src), fn {_o, m} -> m end)
      assert "u.age > 19" in mutated
      assert "u.age > 17" in mutated
      assert "u.age >= 18" in mutated
      assert_compiles(src)
    end

    test "an aggregate inside a having is swapped and woven through the host" do
      # The realistic `having` shape carries an aggregate (`sum(u.age) > n`). Its `sum`↔`avg` swap
      # rides the same `^`/`dynamic` host as the operator swaps — recorded as a clean logical diff
      # on the bare condition, the scaffolding invisible — and the woven `dynamic` must accept the
      # aggregate (it does: `dynamic([u], sum(u.age) > 100)`), so the metamutant compiles.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            group_by: u.role,
            having: sum(u.age) > 100,
            select: u.role
        end
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "sum(u.age) > 100" and mutated == "avg(u.age) > 100"
             end)

      assert metamutant(src) =~ "dynamic([u]"
      assert_compiles(src)
    end

    test "a piped having hosts its aggregate swap too" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> having([u], max(u.age) > 30)
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "max(u.age) > 30" and mutated == "min(u.age) > 30"
             end)

      assert_compiles(src)
    end

    test "binding-reorder swaps the two join bindings and compiles" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            join: p in Post,
            on: p.user_id == u.id,
            where: u.id == p.user_id,
            select: u.id
        end
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "u.id == p.user_id" and mutated == "p.id == u.user_id"
             end)

      assert metamutant(src) =~ "dynamic([u, p]"
      assert_compiles(src)
    end
  end

  describe "binding-list sources (the from rebinding form)" do
    # Regression: a `from` whose source is a *binding list* (`[…] in query`), not a lone `u in S`,
    # used to reach `clean_var/1` with the whole list and crash with a FunctionClauseError. The host
    # now expands the list element-wise: positional bindings swap, named bindings are re-declared but
    # never reordered.

    test "a named-binding source no longer crashes and still hosts the operator swap" do
      # The exact shape from the original crash report: a multi-named rebinding list on the LHS of `in`.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from([descriptor: d, file: f, option: opt, field: field] in query,
            where: d.size > 1,
            select: d.id)
        end
      end
      """

      # The catalog still mutates the condition (boundary bump on the literal `1`)…
      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "d.size > 1" and mutated == "d.size >= 1"
             end)

      # …and the woven dynamic re-declares the full binding list, named bindings intact (a list this
      # long is rendered across lines, so we match the binding list itself, not the `dynamic(` head).
      assert metamutant(src) =~ "[descriptor: d, file: f, option: opt, field: field]"
      assert_compiles(src)
    end

    test "a positional rebinding list swaps its two bindings" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([u, p] in query, where: u.id == p.user_id, select: u.id)
      end
      """

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "u.id == p.user_id" and mutated == "p.id == u.user_id"
             end)

      assert metamutant(src) =~ "dynamic([u, p]"
      assert_compiles(src)
    end

    test "a mixed list reorders only the positional bindings, leaving the named one alone" do
      # `c` is named — present in the condition but excluded from reorder. Only `u`/`p` (positional)
      # transpose; `c.flag` is never reached, so no mutant ever puts a `u`/`p` field onto `c`.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          from([u, p, comments: c] in query,
            where: u.age > p.views and c.flag > u.score,
            select: u.id)
        end
      end
      """

      # The positional swap fires…
      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "u.age > p.views and c.flag > u.score" and
                 mutated == "p.age > u.views and c.flag > p.score"
             end)

      # …but `c` is never reordered: no mutant moves a `u`/`p` field onto the named binding.
      refute Enum.any?(hosted(src), fn {_original, mutated} ->
               mutated =~ "c.age" or mutated =~ "c.views" or mutated =~ "c.score"
             end)

      # The named binding is still re-declared faithfully so the fragment compiles.
      assert metamutant(src) =~ "[u, p, comments: c]"
      assert_compiles(src)
    end
  end

  # The end-to-end tests above confirm *delivery*; the blocks below pin the two public entry
  # points directly — the per-argument treatment list `macro_routing/1` returns, and the target
  # set `host/2` builds — so the routing/shape predicates are exercised on their own, not only
  # incidentally through a compiled metamutant.

  describe "the registered macro lists" do
    test "condition_macros are the where/having family" do
      assert Host.condition_macros() == ~w(where or_where having or_having)a
    end

    test "clause_macros are the plain composable builders" do
      assert Host.clause_macros() ==
               ~w(select select_merge order_by group_by distinct limit offset join preload
                  lock with_cte windows union union_all except intersect)a
    end
  end

  describe "macro_routing/1 — per-argument treatment" do
    defp routing(code), do: code |> Sourceror.parse_string!() |> Host.Routing.macro_routing()

    test "from keyword form: a binding source hosts its clause argument" do
      assert routing("from(u in User, where: u.x == u.y, select: u.id)") == [:skip, :hosted]
    end

    test "from keyword form: a bindingless source routes where-shorthand values per-pair" do
      # The `where:` value is a keyword list → `{:keyword, [:pinned]}` (core mutates the scalar,
      # `^`-pinned); `select:` is not a condition key → `:skip`. The order_by variant proves a
      # *non-condition* clause whose value is itself a keyword list still routes `:skip`, not the
      # condition treatment (pins the `key in @condition_keys` test, not just "has a kw value").
      assert routing(~s|from("users", where: [active: true], select: [:id])|) ==
               [:skip, {:keyword, [{:keyword, [:pinned]}, :skip]}]

      assert routing(~s|from("t", where: [a: 1], order_by: [asc: :x])|) ==
               [:skip, {:keyword, [{:keyword, [:pinned]}, :skip]}]

      assert routing(~s|from("users", select: [:id])|) == [:skip, {:keyword, [:skip]}]
    end

    test "shorthand pair values: scalars pin, nil/interpolation/compound stay raw" do
      assert routing(~s|where(q, name: "x", age: 5, tag: :a, active: true)|) ==
               [:expression, {:keyword, [:pinned, :pinned, :pinned, :pinned]}]

      # nil is an `IS NULL` (never `= nil`); `^v` is already interpolated; a list/field is compound
      # — all raw. (Pins nil_literal?/scalar_literal? and the pair_value_treatment cond.)
      assert routing(~s|where(q, a: nil, b: ^v, c: [1, 2], d: u.x)|) ==
               [:expression, {:keyword, [:skip, :skip, :skip, :skip]}]
    end

    test "condition macros (direct + piped) host the condition after the binding list" do
      assert routing("where(query, [u], u.x == u.y)") == [:expression, :skip, :hosted]
      assert routing("having(query, [u], u.x == u.y)") == [:expression, :skip, :hosted]
      # piped form — the binding list is the first *argument* (the query is the `|>` LHS).
      assert routing("where([u], u.x == u.y)") == [:skip, :hosted]
      # a piped query as the first arg is still recognized as the threaded expression.
      assert routing("where(q |> sub(), [u], u.x == u.y)") == [:expression, :skip, :hosted]
      # a `...`-anchored binding list is recognized too, so its condition routes `:hosted`.
      assert routing("where(query, [..., c], c.x == c.y)") == [:expression, :skip, :hosted]
    end

    test "condition macro with no condition after the binding list hosts nothing" do
      # condition_index requires an argument *after* the binding list, so a binding-only call
      # never marks a position `:hosted`.
      assert routing("where([u])") == [:skip]
      assert routing("where(q, [u])") == [:expression, :skip]
    end

    test "a shorthand condition macro routes its trailing pairs per-pair" do
      assert routing("where(query, active: true)") == [:expression, {:keyword, [:pinned]}]
    end

    test "plain clause macros thread the query and leave every data position raw" do
      assert routing("limit(query, 10)") == [:expression, :skip]
      assert routing("order_by(query, [u], asc: u.x)") == [:expression, :skip, :skip]

      # the threaded query is recognized as a bare var, a from(…), or a pipe — each → :expression.
      assert routing("select(q, [u], u.id)") == [:expression, :skip, :skip]
      assert routing("select(from(u in User), [u], u.id)") == [:expression, :skip, :skip]
      assert routing("select(q |> base(), [u], u.id)") == [:expression, :skip, :skip]
    end

    test "a piped clause macro's first data argument is not the query" do
      # `q |> limit(10)` → `limit(10)`: the `10` is a bound, not the threaded query, so `:skip`.
      assert routing("limit(10)") == [:skip]
    end

    test "a non-routing macro yields []" do
      assert routing("foobar(query, 1)") == []
    end

    test "an empty list is neither a binding list nor a shorthand keyword list" do
      # `[]` must not be mistaken for a binding list (so it never marks a `:hosted` position) nor
      # for shorthand pairs (so it never becomes a `{:keyword, …}` overlay) — both reduce to a raw
      # data argument.
      assert routing("where(q, [])") == [:expression, :skip]
      assert routing("where(q, [], u.x == u.y)") == [:expression, :skip, :skip]
    end
  end

  describe "host/2 — the target set" do
    defp host_originals(code) do
      code
      |> Sourceror.parse_string!()
      |> Host.host(%{opts: [repo: MyApp.Repo]})
    end

    test "a from hosts one target per catalog-mutatable where/having condition" do
      [t] = host_originals("from(u in User, where: u.x == u.y, select: u.id)")
      assert Sourceror.to_string(t.original) == "u.x == u.y"
      assert t.mutants != []
    end

    test "multiple conditions each become their own target, in clause order" do
      targets = host_originals("from(u in User, where: u.x == u.y, having: u.a > u.b)")
      assert Enum.map(targets, &Sourceror.to_string(&1.original)) == ["u.x == u.y", "u.a > u.b"]
      assert Enum.all?(targets, &(&1.mutants != []))
    end

    test "the direct and piped where/having forms each host their condition" do
      for code <- ["where(query, [u], u.x == u.y)", "having(query, [u], u.x == u.y)"] do
        assert [t] = host_originals(code)
        assert Sourceror.to_string(t.original) == "u.x == u.y"
        assert t.mutants != []
      end
    end

    test "nothing hostable yields no targets" do
      assert host_originals(~s|from("users", where: [active: true])|) == []
      assert host_originals("limit(query, 10)") == []
      assert host_originals("from(u in User, select: u.id)") == []
    end

    test "host tolerates a context without :opts (families default to all)" do
      # `opts/1` falls back to `[]` for a context lacking `:opts`, so the host still builds its
      # targets rather than crashing — `[]` reads as the default `:all` families downstream.
      node = Sourceror.parse_string!("from(u in User, where: u.x == u.y, select: u.id)")
      assert [t] = Host.host(node, %{})
      assert Sourceror.to_string(t.original) == "u.x == u.y"
    end
  end

  describe "the recorded diff is a clean logical change" do
    test "neither side leaks the dynamic / ^ / case scaffolding the host weaves" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, where: not is_nil(u.name), select: u.id)
      end
      """

      assert [{original, mutated}] = hosted(src)

      assert original == "not is_nil(u.name)"
      assert mutated == "is_nil(u.name)"

      for code <- [original, mutated] do
        refute code =~ "dynamic"
        refute code =~ "case"
        refute code =~ "^"
      end
    end
  end
end
