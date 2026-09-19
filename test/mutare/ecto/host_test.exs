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
  # always a logical *swap* or bound *bump*, never a deletion. The whole-`from` query mutations now
  # also record clause-level diffs, but a clause *drop* is a DELETE (`mutated == ""`); a hosted
  # mutant always rewrites to non-empty text. That empty-vs-non-empty split is the discriminator.
  defp hosted(source) do
    source
    |> ecto_diffs()
    |> Enum.reject(fn {_original, mutated} -> mutated == "" end)
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
      assert {"p.user_id == u.id", "p.user_id != u.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([u, p]"
      assert_compiles(src)
    end

    test "each join condition sees bindings introduced up to that join, not future joins" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            join: p in Post,
            on: p.user_id == u.id,
            join: c in Comment,
            on: c.post_id == p.id,
            select: u.id
        end
      end
      """

      assert {"p.user_id == u.id", "p.user_id != u.id"} in hosted(src)
      assert {"c.post_id == p.id", "c.post_id != p.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([u, p]"
      assert metamutant(src) =~ "dynamic([u, p, c]"
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

    test "a mixed positional+named source over a literal schema still anchors (composed? false)" do
      # The test above rebinds a *composed* `base` (a bound variable), so `composed?` is already
      # true there and never isolates the `source_named != []` disjunct on its own. Here the source
      # is the literal schema `Post` (`composed?` is false), so anchoring must come from the named
      # rebind alone — proving the disjunct fires independent of `composed?`.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from [a, post: p] in Post,
            inner_join: j in Comment,
            on: j.user_id == a.id,
            where: j.views > 1,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([a, ..., j, post: p]"
      refute metamutant(src) =~ "dynamic([a, j, post: p]"
      assert_compiles(src)
    end

    test "a positional-only source with a join anchors to the tail (composed query)" do
      # `[a, b] in base` rebinds base's *leading* bindings, but base is an external query that can
      # carry more bindings the host can't see — so an appended join lands at the tail, not
      # contiguously at position 2. The woven dynamic must anchor it: `[a, b, ..., j]`. Asserting
      # `[a, b, j]` binds `j` to position 2 — a silently wrong baseline whenever base has a binding
      # between `b` and `j` (see BUG-named-binding-misresolution.md).
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

      assert metamutant(src) =~ "dynamic([a, b, ..., j]"
      refute metamutant(src) =~ "dynamic([a, b, j]"
      assert_compiles(src)
    end

    test "a lone positional source composing a query anchors appended joins (BUG-named-binding-misresolution)" do
      # The reported bug: `from(s in query, inner_join: o, inner_join: uc, where: uc.…)` composes an
      # *external* `query` that already carries hidden bindings. Each appended join lands at the tail,
      # so every hosted condition referencing `uc` must weave the anchored `[s, ..., o, uc]`. The old
      # contiguous `[s, o, uc]` bound `uc` to position 2 — a hidden binding of the base — corrupting
      # the *baseline* (mutant 0) into a query that raises at runtime, not just a bad mutant.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, uid) do
          from(s in query,
            inner_join: o in assoc(s, :org),
            inner_join: uc in assoc(o, :uploader_contacts),
            where: uc.uploader_user_id == ^uid,
            where: uc.rank > 0,
            select: s.id
          )
        end
      end
      """

      assert {"uc.uploader_user_id == ^uid", "uc.uploader_user_id != ^uid"} in hosted(src)
      assert {"uc.rank > 0", "uc.rank >= 0"} in hosted(src)

      # Every hosted condition re-declares the anchored list; none uses the contiguous (wrong) one.
      assert metamutant(src) =~ "dynamic([s, ..., o, uc]"
      refute metamutant(src) =~ "dynamic([s, o, uc]"
      assert_compiles(src)
    end

    test "a function-call source composing a query anchors appended joins to the tail" do
      # A function call (`base(args)`) is just as opaque a composed query as a bound variable: it can
      # return a query carrying hidden bindings, so an appended join must anchor to the tail. The old
      # `composed?` check only recognized a *bare variable* source, so a function-call source dropped
      # the anchor — weaving the contiguous (wrong) `[a, b, j]`, which silently binds `j` to a hidden
      # binding of the returned query whenever it has one between `b` and `j`.
      src = """
      defmodule M do
        import Ecto.Query
        def q(args) do
          from [a, b] in base(args),
            inner_join: j in Post,
            on: j.user_id == a.id,
            where: j.views > b.views,
            select: j.id
        end
        def base(_), do: from(p in "posts")
      end
      """

      assert metamutant(src) =~ "dynamic([a, b, ..., j]"
      refute metamutant(src) =~ "dynamic([a, b, j]"

      # …and the appended join's conditions are actually hosted — real mutants fire, so this can't
      # pass on scaffolding shape alone if every mutation silently vanished.
      assert {"j.user_id == a.id", "j.user_id != a.id"} in hosted(src)
      assert {"j.views > b.views", "j.views >= b.views"} in hosted(src)

      assert_compiles(src)
    end

    test "a subquery source composing a query anchors appended joins to the tail" do
      # `subquery(base)` is a call, not a bare variable, so the pre-fix `composed?` check misread it as
      # a literal source and dropped the anchor. It composes an external query like any other.
      src = """
      defmodule M do
        import Ecto.Query
        def q(base) do
          from [a, b] in subquery(base),
            inner_join: j in Post,
            on: j.user_id == a.id,
            where: j.views > b.views,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([a, b, ..., j]"
      refute metamutant(src) =~ "dynamic([a, b, j]"

      # …and the appended join's conditions are actually hosted — real mutants fire, so this can't
      # pass on scaffolding shape alone if every mutation silently vanished.
      assert {"j.user_id == a.id", "j.user_id != a.id"} in hosted(src)
      assert {"j.views > b.views", "j.views >= b.views"} in hosted(src)

      assert_compiles(src)
    end

    test "literal schema / string / tuple sources keep joins contiguous (no spurious anchor)" do
      # The other side of the `composed?` rule: a literal queryable contributes exactly the bindings
      # its pattern names, so an appended join follows contiguously and must *not* be `...`-anchored.
      for source <- ["Post", ~s("posts"), ~s({"posts", Post})] do
        src = """
        defmodule M do
          import Ecto.Query
          def q do
            from a in #{source},
              inner_join: j in Comment,
              on: j.post_id == a.id,
              where: j.views > a.views,
              select: j.id
          end
        end
        """

        assert metamutant(src) =~ "dynamic([a, j]",
               "expected contiguous bindings for source #{source}"

        refute metamutant(src) =~ "dynamic([a, ..., j]"
        assert_compiles(src)
      end
    end

    test "a tuple source with a dynamic table name (non-literal source half) still anchors a join" do
      # `{table_var, Post}` — a dynamic table name paired with a literal schema — is *not* a
      # literal queryable overall: `literal_queryable?/1`'s tuple clause requires *both* halves
      # literal (`and`), so a bound-variable table name still marks the source opaque and the
      # appended join anchors to the tail, exactly as a bound-variable/function-call source does.
      src = """
      defmodule M do
        import Ecto.Query
        def q(table_var) do
          from a in {table_var, Post},
            inner_join: j in Comment,
            on: j.post_id == a.id,
            where: j.views > a.views,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([a, ..., j]"
      refute metamutant(src) =~ "dynamic([a, j]"
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

    test "a bare literal source (no binding form at all) still anchors an appended join" do
      # Unlike the case above, `composed?` is *false* here (`"posts"` is a literal queryable, not a
      # bound query variable) — this isolates the `source_positional == []` disjunct on its own:
      # a source written with no `x in` binding form at all occupies binding position 0 anonymously
      # (nothing to declare), so an appended join still can't be assumed contiguous at position 0 and
      # must anchor, even though the source itself is perfectly literal/non-composed.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from "posts",
            inner_join: j in Post,
            on: j.user_id == 1,
            where: j.views > 1,
            select: j.id
        end
      end
      """

      assert metamutant(src) =~ "dynamic([..., j]"
      refute metamutant(src) =~ "dynamic([j]"
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

    test "an unnamed join still occupies its binding slot: `[p, _, c]`, not `[p, c]`" do
      # Regression: Ecto binds a join written without `x in` anonymously and *still advances the
      # binding count* (`Ecto.Query.Builder.Join.escape/3` answers `:_` for it), so here `p` is &0,
      # the `"audit"` cross join &1, and `c` &2. The host used to collect only the joins that
      # declare a variable and wove `[p, c]` — binding `c` to &1, the audit table, in *every* branch
      # of the selector, the baseline included. With same-named columns on both tables that is
      # valid SQL returning the wrong rows, which `assert_compiles` can never see; the oracle test
      # below and the semantic suite's "Anonymous join slots" fixtures are what prove the positions.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in "posts",
            cross_join: "audit",
            join: c in "comments",
            on: c.post_id == p.id,
            where: c.score > 10,
            select: c.id
        end
      end
      """

      assert {"c.post_id == p.id", "c.post_id != p.id"} in hosted(src)
      assert {"c.score > 10", "c.score >= 10"} in hosted(src)
      assert metamutant(src) =~ "dynamic([p, _, c]"
      refute metamutant(src) =~ "dynamic([p, c]"
      assert_compiles(src)
    end

    test "an unnamed join between and after named ones holds its slot too" do
      # Between: `d` is &3, past the anonymous &2. After: the trailing `_` is redundant under a
      # literal source (nothing follows it to displace) but is emitted all the same — one slot per
      # join is the whole rule, and under a composed source that same trailing slot is load-bearing
      # (next test). Each `on:` still sees only the joins up to its own.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in "posts",
            join: c in "comments",
            on: c.post_id == p.id,
            cross_join: "audit",
            join: d in "comments",
            on: d.id == c.id,
            cross_join: "audit",
            where: d.score > 10,
            select: d.id
        end
      end
      """

      mm = metamutant(src)
      assert mm =~ "dynamic([p, c], c.post_id"
      assert mm =~ "dynamic([p, c, _, d], d.id"
      assert mm =~ "dynamic([p, c, _, d, _]"
      assert_compiles(src)
    end

    test "under a composed source an unnamed join counts from the tail: `[p, ..., c, _]`" do
      # The `...` anchor counts the entries after it back from the query's *last* binding, so a
      # dropped slot is just as wrong at the tail as at the front: after `join: c`, an unnamed join
      # is the last binding and `c` the second-to-last. The old `[p, ..., c]` named the audit join
      # `c`. (An ellipsis alone can't repair a missing slot — it only says where counting starts.)
      src = """
      defmodule M do
        import Ecto.Query
        def q(base) do
          from p in base,
            cross_join: "audit",
            join: c in "comments",
            on: c.post_id == p.id,
            cross_join: "audit",
            where: c.score > 10,
            select: c.id
        end
      end
      """

      mm = metamutant(src)
      assert mm =~ "dynamic([p, ..., _, c], c.post_id"
      assert mm =~ "dynamic([p, ..., _, c, _]"
      refute mm =~ "dynamic([p, ..., c]"
      assert_compiles(src)
    end

    test "every unnamed join source shape holds exactly one slot" do
      # Ecto's join builder binds each of these anonymously (`:_`): a table string, a schema, a
      # `{table, schema}` pair, a `subquery`, a `fragment`, an interpolated source, and an `assoc`
      # (a `left_join`, its condition being implicit; the rest are cross joins, which need none).
      for {join, source} <- [
            {"cross_join", ~s("audit")},
            {"cross_join", "Audit"},
            {"cross_join", ~s({"audit", Audit})},
            {"cross_join", "subquery(inner)"},
            {"cross_join", ~s|fragment("select 1 as post_id")|},
            {"cross_join", "^inner"},
            {"left_join", "assoc(p, :audits)"}
          ] do
        src = """
        defmodule M do
          import Ecto.Query
          def q(inner) do
            from p in Post,
              #{join}: #{source},
              join: c in Comment,
              on: c.post_id == p.id,
              where: c.score > 10,
              select: c.id
          end
        end
        """

        assert metamutant(src) =~ "dynamic([p, _, c]",
               "expected the unnamed join #{source} to hold slot 1"

        assert_compiles(src)
      end
    end

    test "an unnamed join's own `on:` re-declares its slot" do
      # The unnamed join's condition can't name the join positionally, but it is hosted like any
      # other sole, top-level `on:` — and the slot it occupies is declared, so the list has the
      # query's true width at that point.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from p in "posts", join: "audit", on: p.id > 1, select: p.id
        end
      end
      """

      assert {"p.id > 1", "p.id >= 1"} in hosted(src)
      assert metamutant(src) =~ "dynamic([p, _]"
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

  describe "the from keyword form, written bracketed" do
    # `from(p in S, [where: …])` is the same call with the keyword list written in brackets
    # (Sourceror wraps that list in a `__block__`). Its clauses route and host exactly like the
    # bare form — the `where:` condition is woven, and the metamutant compiles.
    test "a bracketed clause list hosts its where condition like the bare form" do
      bare = """
      defmodule M do
        import Ecto.Query
        def q, do: from(p in MyApp.Post, where: p.views > 10)
      end
      """

      bracketed = """
      defmodule M do
        import Ecto.Query
        def q, do: from(p in MyApp.Post, [where: p.views > 10])
      end
      """

      assert hosted(bracketed) == hosted(bare)
      assert {"p.views > 10", "p.views >= 10"} in hosted(bracketed)
      assert_compiles(bracketed)
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

    test "a piped join hosts its on condition, anchoring the joined binding to the tail" do
      # `query` is external (a standalone/piped join always composes one), so the joined `p` lands at
      # the tail of query's bindings, not contiguously at position 1. The woven dynamic anchors it:
      # `[u, ..., p]`. A contiguous `[u, p]` binds `p` to position 1 — wrong whenever query carries a
      # binding before the join (the standalone twin of BUG-named-binding-misresolution.md).
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          query
          |> join(:inner, [u], p in Post, on: p.user_id == u.id)
        end
      end
      """

      assert {"p.user_id == u.id", "p.user_id != u.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([u, ..., p]"
      assert_compiles(src)
    end

    test "a standalone join with an empty binding list hosts its on condition ([..., p])" do
      # `join(q, :inner, [], p in Post, on: …)` is the legal way to write "the on-condition
      # references no prior binding": Ecto's `join/5` can't skip its middle `binding \\ []`
      # default once `opts` is written, so the empty list is a real declaration, not an absent
      # one. Before, the host located the written list through `BindingList.find/1` — which
      # declines `[]` (nothing to reorder) — so the join fell through to raw and only its stage
      # drop was recorded: the comparison and literal mutants on `p.views > 1` vanished. The
      # woven dynamic re-declares exactly the joined binding, tail-anchored: `dynamic([..., p], …)`.
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          join(query, :inner, [], p in Post, on: p.views > 1)
        end
      end
      """

      assert {"p.views > 1", "p.views >= 1"} in hosted(src)
      assert {"p.views > 1", "p.views > 2"} in hosted(src)
      assert metamutant(src) =~ "dynamic([..., p]"
      assert_compiles(src)
    end

    test "the piped empty-binding join hosts its on condition too" do
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          query
          |> join(:inner, [], p in Post, on: p.views > 1)
        end
      end
      """

      assert {"p.views > 1", "p.views >= 1"} in hosted(src)
      assert metamutant(src) =~ "dynamic([..., p]"
      assert_compiles(src)
    end

    test "a standalone unnamed join hosts its on condition, re-declaring the joined slot as `_`" do
      # `join(q, :inner, [p], "audit", on: …)` names no variable for the join it adds, but the
      # join still takes the query's next position, and its `on:` is resolved with that join in
      # place. So the woven list declares the slot — `[p, ..., _]` — exactly as a `from`'s does
      # (`Mutare.Ecto.Host.Bindings`). The host used to weave nothing here, and the comparison and
      # literal mutants of the condition were lost; only the stage drop was recorded.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: join(query, :inner, [p], "audit", on: p.id > 1)
      end
      """

      assert {"p.id > 1", "p.id >= 1"} in hosted(src)
      assert {"p.id > 1", "p.id > 2"} in hosted(src)
      assert metamutant(src) =~ "dynamic([p, ..., _]"
      assert_compiles(src)
    end

    test "a written `...` list keeps its tail meaning: `[..., x]` weaves `[..., x, _]`" do
      # The case the placeholder is load-bearing for. The author's `[..., x]` names the query's
      # last binding *before* the join; the woven dynamic is resolved *after* it, when the unnamed
      # join is the last binding and `x` the second-to-last. Re-declaring the written list alone
      # (`[..., x]`) would name the audit join `x` — in the baseline branch too.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: join(query, :inner, [..., x], "audit", on: x.score > 10)
      end
      """

      assert {"x.score > 10", "x.score >= 10"} in hosted(src)
      assert metamutant(src) =~ "dynamic([..., x, _]"
      refute metamutant(src) =~ "dynamic([..., x]"
      assert_compiles(src)
    end

    test "the piped unnamed join hosts a condition on the binding its `as:` names" do
      # The shape an unnamed join's `on:` most plausibly takes: the join is reachable only through
      # its `as:` name, which resolves against the query the dynamic is spliced into.
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          query
          |> join(:inner, [p], "audit", as: :audit, on: as(:audit).post_id == p.id)
        end
      end
      """

      assert {"as(:audit).post_id == p.id", "as(:audit).post_id != p.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([p, ..., _]"
      assert_compiles(src)
    end

    test "every unnamed standalone join source shape hosts, one slot each (an `assoc` excepted)" do
      for source <- [
            ~s("audit"),
            "Audit",
            ~s({"audit", Audit}),
            "subquery(inner)",
            ~s|fragment("select 1 as post_id")|,
            "^inner"
          ] do
        src = """
        defmodule M do
          import Ecto.Query
          def q(query, inner), do: join(query, :inner, [], #{source}, on: as(:post).id > 1)
        end
        """

        assert {"as(:post).id > 1", "as(:post).id >= 1"} in hosted(src),
               "expected the unnamed join #{source} to host its on:"

        assert metamutant(src) =~ "dynamic([..., _]"
        assert_compiles(src)
      end
    end
  end

  describe "binding-less conditions (no written binding list)" do
    # `q |> where(cond)` ≡ `where(q, [], cond)`: with no positional binding list, a condition that
    # references a *named* binding (`as(:_)`) — or a `fragment`/`parent_as` — is still a real SQL
    # predicate. The host weaves it behind an empty-binding `dynamic([], …)`, the very form Ecto
    # accepts for `where(q, ^dynamic)`. Before this, such a condition was silently left raw — a false
    # negative, since the operator/literal swaps never fired.

    test "a piped binding-less where hosts the operator and literal swaps" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(p in "posts", as: :post)
          |> where(as(:post).views > 100)
        end
      end
      """

      assert {"as(:post).views > 100", "as(:post).views >= 100"} in hosted(src)
      assert {"as(:post).views > 100", "as(:post).views > 101"} in hosted(src)
      assert metamutant(src) =~ "dynamic([], as(:post).views"
      assert_compiles(src)
    end

    test "the direct binding-less form hosts its comparison swap too" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, as(:post).name == "ok")
      end
      """

      assert {"as(:post).name == \"ok\"", "as(:post).name != \"ok\""} in hosted(src)
      assert metamutant(src) =~ "dynamic([]"
      assert_compiles(src)
    end

    test "a binding-less having hosts its null predicate" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: query |> having(is_nil(as(:post).deleted_at))
      end
      """

      assert {"is_nil(as(:post).deleted_at)", "not is_nil(as(:post).deleted_at)"} in hosted(src)
      assert metamutant(src) =~ "dynamic([]"
      assert_compiles(src)
    end

    test "a `^dynamic` operand weaves nothing — it is mutated where it is built" do
      # The condition is a pre-built dynamic interpolated with `^`: Ecto's own composition primitive.
      # The pin is hosted like any condition, but the SQL catalog stops at it and its interior is a
      # bare variable core mutates nowhere (`Mutare.Ecto.Island`), so no target forms and no
      # `dynamic(` scaffolding is woven (the one mutation is the orthogonal stage drop). The
      # dynamic's own SQL mutates at its build site (`Mutare.Ecto.Dynamic`).
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, filter), do: query |> where(^filter)
      end
      """

      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a top-level interpolation in a from clause is outside the SQL catalog — plugin alone, nothing woven" do
      # Hosted (`where: ^cond` routes `:hosted`, see the routing tests below), but the SQL catalog
      # stops at the pin and the plugin alone has nothing for the Elixir interior — so no target
      # forms. With core's families on, the interior sub-contracts (subcontract_test.exs, "a
      # top-level-pin condition sub-contracts its interior in every hosted form").
      src = """
      defmodule M do
        import Ecto.Query
        def q(x), do: from(User, where: ^(x > 1))
      end
      """

      assert hosted(src) == []
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a top-level interpolation is untouched by the SQL catalog alongside a hosted bare-source condition" do
      src = """
      defmodule M do
        import Ecto.Query

        def q(x) do
          from("posts",
            as: :post,
            where: as(:post).views > 100,
            where: ^(x > 1)
          )
        end
      end
      """

      assert {"as(:post).views > 100", "as(:post).views >= 100"} in hosted(src)
      refute Enum.any?(hosted(src), fn {original, _mutated} -> original == "^(x > 1)" end)
      refute metamutant(src) =~ "^(x >= 1)"
      assert_compiles(src)
    end

    test "a bare-queryable `from` hosts a named-binding where (empty-binding dynamic)" do
      # The `from`-keyword twin: a bare source (`from("posts", …)`, no `p in S`) declares no
      # positional binding, but an `as:` lets its `where:` reference a named one — still a real SQL
      # predicate. The host weaves `dynamic([], …)`; before this it was left raw (the false negative).
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from("posts", as: :post, where: as(:post).views > 100, select: as(:post).id)
      end
      """

      assert {"as(:post).views > 100", "as(:post).views >= 100"} in hosted(src)
      assert {"as(:post).views > 100", "as(:post).views > 101"} in hosted(src)
      assert metamutant(src) =~ "dynamic([], as(:post).views"
      assert_compiles(src)
    end

    test "a piped `from` hosts exactly what its direct twin does (bare source)" do
      # `Post |> from(…)`: the source is the `|>` left side, so the call's one visible argument is
      # the clause list. Before this it landed in the source slot and the whole call stayed raw —
      # zero mutants for a perfectly ordinary query. Now `FromCall` places the clauses by
      # `pipe_mode`, so the named-binding condition hosts behind an empty-binding `dynamic([], …)`
      # and the literal bound weaves pin-only, exactly as in `from(Post, …)`.
      piped = """
      defmodule M do
        import Ecto.Query
        def q, do: Post |> from(as: :post, where: as(:post).views > 100, limit: 5)
      end
      """

      direct = """
      defmodule M do
        import Ecto.Query
        def q, do: from(Post, as: :post, where: as(:post).views > 100, limit: 5)
      end
      """

      assert hosted(piped) == hosted(direct)
      assert {"as(:post).views > 100", "as(:post).views >= 100"} in hosted(piped)
      assert {"5", "6"} in hosted(piped)

      # Core hoists the piped stage (it also carries whole-call drop mutants) into a closure over
      # the pipe's left side, so the woven `from(…)` reads `mutare_piped |> from(…)`: the
      # condition pinned behind an empty-binding `dynamic`, the bound pinned bare.
      mm = metamutant(piped)
      assert mm =~ ~r/mutare_piped\s*\|> from\(\s*as: :post,\s*where:\s*\^case/
      assert mm =~ "dynamic([], as(:post).views"
      assert mm =~ ~r/limit:\s*\^case/
      refute mm =~ "from(Post"
      assert_compiles(piped)
    end

    test "a piped `from`'s shorthand where pins its scalar value (core's family, `^`-delivered)" do
      # The keyword-shorthand twin: the clause list routes per pair, so core's boolean family
      # mutates `true` behind a pin — the same delivery as `from(Post, where: [active: true])`.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: Post |> from(where: [active: true], select: [:id])
      end
      """

      with_core = [:all, {Mutare.Ecto, repo: MyApp.Repo}]
      assert {:boolean, "true", "false"} in diffs(src, mutators: with_core)
      assert metamutant(src, mutators: with_core) =~ ~r/where: \[\s*active:\s*\^case/
      assert_compiles(src, mutators: with_core)
    end
  end

  describe "totality — a degenerate zero-arg macro yields no hosted target" do
    # Core routes an argless `q |> limit()` / `q |> where()` like any other call (the macros
    # register with `:any` arity), so `Host.Routing` sees an empty `args` for real. It stays
    # total: `query_threading_route/2` routes no argument, `Condition.locate/3` reads the lone
    # threaded query as an arity the macro does not have (the next test), and the
    # trailing-argument readers get `List.last([])`, which is `nil` — no keyword filter, no
    # literal bound. Routing never marks such a call `:hosted` (there is no literal bound, no
    # condition), so `Host.host/2` is never offered it — `bound_target/2` needs no fallback of
    # its own.
    test "a piped limit()/offset()/where() with no explicit argument hosts nothing, never crashes" do
      for code <- ["limit()", "offset()", "where()"] do
        src = """
        defmodule M do
          import Ecto.Query
          def q(query), do: query |> #{code}
        end
        """

        assert hosted(src) == []
      end
    end

    # The clause-level pins for `Host.Condition.locate/3`: an arity the macro does not have
    # (no argument at all, a lone query) and a binding list with nothing after it
    # (`where(q, [p])`, which Ecto itself rejects) are all "no hosted condition" — never a
    # `%Condition{}` with a `nil` node or an out-of-range index.
    test "locate/3 is nil for a degenerate arity and for a trailing binding list" do
      assert Host.Condition.locate(:condition, [], :unpiped) == nil
      assert Host.Condition.locate(:condition, [], :piped) == nil
      assert Host.Condition.locate(:dynamic, [], :unpiped) == nil
      assert Host.Condition.locate(:dynamic, [], :piped) == nil

      [q, binding_list] = Sourceror.parse_string!("f(q, [p])") |> elem(2)
      assert Host.Condition.locate(:condition, [q], :unpiped) == nil
      assert Host.Condition.locate(:condition, [q, binding_list], :unpiped) == nil
      assert Host.Condition.locate(:condition, [binding_list], :piped) == nil
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

  describe "multi-condition join `on:` is not hosted (BUG-multi-condition-join-on)" do
    # A `^dynamic(...)` is legal only as a join's *entire, top-level* on-expression. Ecto folds a
    # join's multiple/implicit on-conditions into one `and`, where a `^dynamic` operand is rejected
    # ("dynamic expressions can only be interpolated at the top level…"). Because the host wraps even
    # the *baseline* branch, hosting such an `on:` corrupts mutant id 0 — the whole `mix mutare` run
    # aborts on a non-green baseline. So the host must leave these `on:` conditions raw. `where`/
    # `having`, each its own independent clause, are unaffected and keep hosting.

    test "a join with two `on:` keys hosts neither — no dynamic woven" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            inner_join: p in Post,
            on: p.user_id == u.id,
            on: p.published == true,
            select: u.id
        end
      end
      """

      assert hosted(src) == []
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "an on: clause with no owning join (malformed) hosts nothing, never crashes" do
      # `group_on/2` groups each `on:` under the *preceding* join clause; an `on:` with no join
      # before it groups under a `nil` key. `hostable_group/1`'s `{nil, _on_indices}` clause is
      # the only one that can ever match a `nil` group (the other two require a real `{join_index,
      # value}` tuple) — dropping it would crash with a `FunctionClauseError` instead of correctly
      # treating the clause as unhostable. Ecto itself rejects this at expansion ("on keyword must
      # immediately follow a join"), so this is a scan-only check — no `assert_compiles`.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User, on: u.x == 1, select: u.id
        end
      end
      """

      assert hosted(src) == []
      refute metamutant(src) =~ "dynamic("
    end

    test "an `assoc` join (implicit on) with an explicit `on:` is not hosted" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            inner_join: p in assoc(u, :posts),
            on: p.published == true,
            select: u.id
        end
      end
      """

      assert hosted(src) == []
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a standalone `assoc` join with an `on:` is not hosted" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          User
          |> join(:inner, [u], p in assoc(u, :posts), on: p.published == true)
          |> select([u], u.id)
        end
      end
      """

      # The stage-drop mutants (collapse a stage to `identity()`) still fire; the guard is that the
      # `on:` weaves no `^dynamic` — were it hosted, a `dynamic(` would appear in the metamutant.
      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "an unnamed `assoc` join is an `assoc` join: its `on:` is not hosted either" do
      # `assoc(u, :posts)` carries its implicit condition whether or not the join names a variable,
      # so the exclusion is read off the join's *source*, not off an `x in` around it. The unnamed
      # spelling used to slip past the rule in the `from` form (its `on:` was hosted); in the
      # standalone form it must not start to, now that unnamed joins host at all.
      for src <- [
            """
            defmodule M do
              import Ecto.Query
              def q do
                from u in User, left_join: assoc(u, :posts), on: u.age > 1, select: u.id
              end
            end
            """,
            """
            defmodule M do
              import Ecto.Query
              def q do
                User
                |> join(:left, [u], assoc(u, :posts), on: u.age > 1)
                |> select([u], u.id)
              end
            end
            """
          ] do
        refute metamutant(src) =~ "dynamic("
        assert_compiles(src)
      end
    end

    test "a standalone join with two `on:` keys is not hosted" do
      # The standalone/pipe twin of the from-keyword "two on: keys" case above
      # (`JoinOn.hostable_standalone?/2`'s own `Enum.count(..., :on) == 1` guard).
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          query
          |> join(:inner, [u], p in Post, on: p.a == 1, on: p.b == 2)
        end
      end
      """

      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a standalone join finds `on:` among other keyword options, not just the first" do
      # `Enum.find_index(options.entries, &(&1.key == :on))` must locate `:on` wherever it sits in
      # the trailing keyword options — here behind `as:` — not assume it's the first entry.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query) do
          query
          |> join(:inner, [u], p in Post, as: :p, on: p.user_id == u.id)
        end
      end
      """

      assert {"p.user_id == u.id", "p.user_id != u.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a single plain `on:` is still hosted (the sole, top-level on-expression)" do
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from u in User,
            inner_join: p in Post,
            on: p.user_id == u.id,
            select: u.id
        end
      end
      """

      assert {"p.user_id == u.id", "p.user_id != u.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([u, p]"
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

    # A binding-reorder is no longer a host-delivered catalog family — it swaps a written binding list
    # in place (`Mutare.Ecto.BindingReorder` for the standalone/pipe macros, `Mutare.Ecto.Query` for a
    # `from` source list), tested in `binding_reorder_test.exs`. The host's only remaining duty for a
    # binding-list shape is to re-declare the bindings in the woven `dynamic` for the *operator* swaps.

    test "a synthesized join binding list is not reordered (only author-written lists are)" do
      # Here `[u, p]` is synthesized from `u in User` + `join: p in Post` — the author never wrote a
      # positional list, so there is nothing they could have transposed. The reorder must not fire
      # (it would mutate a list we invented); the operator swap on the same condition still delivers.
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

      refute Enum.any?(hosted(src), fn {original, mutated} ->
               original == "u.id == p.user_id" and mutated == "p.id == u.user_id"
             end)

      # …but the comparison swap on that same `where` condition is delivered as usual.
      assert {"u.id == p.user_id", "u.id != p.user_id"} in hosted(src)
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

    test "a positional rebinding list re-declares its bindings for the operator swap" do
      # The reorder of *this* source list is a whole-`from` mutation (`Mutare.Ecto.Query`, covered in
      # binding_reorder_test); here we pin the host's remaining duty — the operator swap on the
      # condition delivers, with the woven dynamic re-declaring [u, p].
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: from([u, p] in query, where: u.id == p.user_id, select: u.id)
      end
      """

      assert {"u.id == p.user_id", "u.id != p.user_id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([u, p]"
      assert_compiles(src)
    end

    test "a mixed positional+named list is re-declared faithfully for the operator swap" do
      # The source list's reorder (positional `u`/`p` only, `c` left alone) is a whole-`from` mutation
      # tested in binding_reorder_test; here we pin that the host re-declares the full mixed list in the
      # woven dynamic so the operator swap on the condition compiles.
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

      assert Enum.any?(hosted(src), fn {original, mutated} ->
               original == "u.age > p.views and c.flag > u.score" and
                 mutated == "u.age >= p.views and c.flag > u.score"
             end)

      assert metamutant(src) =~ "[u, p, comments: c]"
      assert_compiles(src)
    end
  end

  describe "the declaration grammar is Ecto's, and an unread declaration is never an empty one" do
    # Ecto's `escape_bind/1` reads two entry forms beyond `var` / `name: var` / `...`: an
    # interpolated name (`{^name, p}`) and an explicit index (`{p, 0}`). The host located the
    # declaration by *searching* the arguments for a list it could read — so one it could not
    # read was indistinguishable from none, the condition fell to the binding-less form, and the
    # weave was `dynamic([], p.score > 10)`: an unbound `p`, failing the single build. The slot
    # is now read by position (`Mutare.Ecto.Host.Condition`), its entries by Ecto's own grammar
    # (`Mutare.Ecto.Binding`), and whatever is still unread is never woven: its condition is
    # rebuilt whole-call (`Mutare.Ecto.StaticCondition`, and `static_condition_test.exs`).

    # The standalone/piped forms and a `from` source all re-declare the written entry verbatim.
    for {label, declaration} <- [
          {"an interpolated name", "{^name, p}"},
          {"a module-attribute name", "{^@name, p}"},
          {"an explicit index", "{p, 0}"},
          {"the tuple spelling of a named binding", "{:post, p}"}
        ] do
      test "#{label} is re-declared in the woven dynamic (where, piped where, from)" do
        declaration = unquote(declaration)

        for stage <- [
              "where(query, [#{declaration}], p.score > 10)",
              "query |> where([#{declaration}], p.score > 10)",
              "from([#{declaration}] in query, where: p.score > 10)",
              "from(#{declaration} in query, where: p.score > 10)"
            ] do
          src = """
          defmodule M do
            import Ecto.Query
            @name :post
            def q(query, name), do: {name, @name, #{stage}}
          end
          """

          assert {"p.score > 10", "p.score >= 10"} in hosted(src), stage
          refute metamutant(src) =~ "dynamic([]", stage
          assert_compiles(src)
        end
      end
    end

    test "the written entries are re-declared as written, in order" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, name) do
          where(query, [{a, 0}, {c, 2}, {^name, p}], c.x > a.x and p.x > 1)
        end
      end
      """

      assert metamutant(src) =~ "dynamic([{a, 0}, {c, 2}, {^name, p}]"
      assert_compiles(src)
    end

    test "a free-standing dynamic mutates under any declaration: it re-emits the written list" do
      # `Mutare.Ecto.Dynamic` rebuilds the whole call, so it never needs to *read* the list.
      src = """
      defmodule M do
        import Ecto.Query
        def d(index), do: dynamic([{p, index}], p.score > 10)
      end
      """

      assert {"p.score > 10", "p.score >= 10"} in ecto_diffs(src)
      assert metamutant(src) =~ "dynamic([{p, index}], p.score >= 10)"
      assert_compiles(src)
    end

    test "a standalone join appends its binding to an indexed declaration, tail-anchored" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: join(query, :inner, [{p, 0}], c in Comment, on: c.post_id == p.id)
      end
      """

      assert {"c.post_id == p.id", "c.post_id != p.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([{p, 0}, ..., c]"
      assert_compiles(src)
    end

    test "two entries over a literal source's one binding anchor its joins" do
      # A literal source is ONE binding, so the join is binding 1 — while a contiguous
      # `[{p, 0}, {q, 0}, c]` (or `[p, q, c]`) would call it binding 2.
      for {declaration, woven} <- [
            {"[{p, 0}, {q, 0}]", "dynamic([{p, 0}, {q, 0}, ..., c]"},
            {"[p, q]", "dynamic([p, q, ..., c]"}
          ] do
        src = """
        defmodule M do
          import Ecto.Query
          def q do
            from(#{declaration} in Post, join: c in Comment, on: c.post_id == p.id, where: c.id > q.id)
          end
        end
        """

        assert metamutant(src) =~ woven
        assert_compiles(src)
      end
    end

    test "a single indexed entry over a literal source keeps its joins contiguous" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from([{p, 0}] in Post, join: c in Comment, on: c.post_id == p.id)
      end
      """

      assert metamutant(src) =~ "dynamic([{p, 0}, c]"
      assert_compiles(src)
    end

    test "a join written without `in` holds its binding position as `_`" do
      # `join: assoc(p, :comments)` names no variable but is binding 1, so `u` is binding 2.
      # Skipping it re-declared `[p, u]` — `u` bound to the *comments* join, in the unmutated
      # branch as much as in every mutant.
      src = """
      defmodule M do
        import Ecto.Query
        def q do
          from(p in Post, join: assoc(p, :comments), join: u in User, on: true, where: u.id > p.id)
        end
      end
      """

      assert {"u.id > p.id", "u.id >= p.id"} in hosted(src)
      assert metamutant(src) =~ "dynamic([p, _, u]"
      assert_compiles(src)
    end

    test "a keyword shorthand after a written declaration routes per pair, as it does without one" do
      # A list condition is the shorthand form whether or not a declaration precedes it.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, [p], score: 10)
      end
      """

      all = [:all, {Mutare.Ecto, repo: MyApp.Repo}]
      diffs = diffs(src, mutators: all)

      # Core's literal family mutates the value, `^`-pinned; the column key and the written
      # declaration stay raw, and nothing is woven behind a `dynamic`.
      assert {:integer, "10", "11"} in diffs
      refute Enum.any?(diffs, fn {_mutator, original, _} -> original in ["score:", "[p]"] end)
      refute metamutant(src, mutators: all) =~ "dynamic("
      assert_compiles(src, mutators: all)
    end
  end

  describe "Host.Condition.locate/3 — the declaration's three outcomes" do
    alias Mutare.Ecto.AST.BindingList

    defp call_args(code), do: code |> Sourceror.parse_string!() |> elem(2)

    test "written: the slot before the condition, by position, in the direct and piped forms" do
      assert %Host.Condition{index: 2, declaration: %BindingList{entries: [{:positional, _}]}} =
               Host.Condition.locate(:condition, call_args("where(q, [p], p.x > 1)"), :unpiped)

      assert %Host.Condition{index: 1, declaration: %BindingList{entries: [{:named, :post, _}]}} =
               Host.Condition.locate(:condition, call_args("where([post: p], p.x > 1)"), :piped)

      assert %Host.Condition{index: 1, declaration: %BindingList{entries: [{:indexed, _, 0}]}} =
               Host.Condition.locate(:dynamic, call_args("dynamic([{p, 0}], p.x > 1)"), :unpiped)
    end

    test "written empty is a declaration of nothing, not an omitted one" do
      assert %Host.Condition{index: 2, declaration: %BindingList{entries: []}} =
               Host.Condition.locate(
                 :condition,
                 call_args("where(q, [], as(:p).x > 1)"),
                 :unpiped
               )
    end

    test "omitted: the arity says no declaration was written" do
      assert %Host.Condition{index: 1, declaration: :omitted} =
               Host.Condition.locate(:condition, call_args("where(q, as(:p).x > 1)"), :unpiped)

      assert %Host.Condition{index: 0, declaration: :omitted} =
               Host.Condition.locate(:condition, call_args("where(as(:p).x > 1)"), :piped)

      assert %Host.Condition{index: 0, declaration: :omitted} =
               Host.Condition.locate(:dynamic, call_args("dynamic(as(:p).x > 1)"), :unpiped)
    end

    test "uninterpretable: written, but unread — and never reported as omitted" do
      for code <- ["where(q, [{p, index}], p.x > 1)", "where(q, bindings, p.x > 1)"] do
        assert %Host.Condition{index: 2, declaration: :uninterpretable} =
                 Host.Condition.locate(:condition, call_args(code), :unpiped)
      end

      # A piped `dynamic`'s declaration is the pipe's hidden left side: written, but unseen.
      assert %Host.Condition{index: 0, declaration: :uninterpretable} =
               Host.Condition.locate(:dynamic, call_args("dynamic(p.x > 1)"), :piped)
    end

    test "Bindings.declarations/1 keeps the three apart" do
      {:ok, written} = BindingList.parse(Sourceror.parse_string!("[p]"))

      assert Host.Bindings.declarations(written) == {:ok, [{:p, [], nil}]}
      assert Host.Bindings.declarations(:omitted) == {:ok, []}
      assert Host.Bindings.declarations(:uninterpretable) == :error
    end
  end

  describe "the threaded query is routed by form, not shape" do
    # `Host.Routing` marks a directly written queryable `:expression` whatever it is: the upstream
    # mutations of a *computed* query must stay reachable through the stage exactly as a bare
    # variable's or a nested `from(…)`'s are, and the direct and piped forms must agree. Only a
    # structural queryable stays raw.
    @with_core [:all, {Mutare.Ecto, repo: MyApp.Repo}]

    test "a computed query's interior is mutated by core, in the direct form as in the piped" do
      for call <- [
            "where(base_query(2), [p], p.views > 1)",
            "base_query(2) |> where([p], p.views > 1)"
          ] do
        src = """
        defmodule Posts do
          import Ecto.Query
          def base_query(n), do: from(p in "posts", where: p.id > ^n)
          def q, do: #{call}
        end
        """

        diffs = diffs(src, mutators: @with_core)
        # core's integer family reaches the computed query's argument …
        assert {:integer, "2", "3"} in diffs
        assert {:integer, "2", "0"} in diffs
        # … while the plugin still hosts the condition beside it.
        assert {:ecto, "p.views > 1", "p.views >= 1"} in diffs
        assert_compiles(src, mutators: @with_core)
      end
    end

    test "a structural queryable is never mutated" do
      # A schema alias, a table-name string, or a `{"table", Schema}` pair names a table rather
      # than computing a query: none of core's `:alias`/`:string`/`:tuple` families reach it,
      # while the condition beside it is still hosted.
      for source <- ["Post", ~S|"posts"|, ~S|{"posts", Post}|],
          piped? <- [false, true] do
        src = """
        defmodule Posts do
          import Ecto.Query
          def q, do: #{if piped?, do: "#{source} |> where([p], p.views > 1)", else: "where(#{source}, [p], p.views > 1)"}
        end
        """

        diffs = diffs(src, mutators: @with_core)
        refute Enum.any?(diffs, fn {family, _, _} -> family in [:alias, :string, :tuple] end)
        assert {:ecto, "p.views > 1", "p.views >= 1"} in diffs
        assert_compiles(src, mutators: @with_core)
      end
    end

    test "a piped from holds structural sources raw while hosting its clauses" do
      for source <- ["Post", ~S|"posts"|, ~S|{"posts", Post}|] do
        src = """
        defmodule Posts do
          import Ecto.Query
          def q, do: #{source} |> from(as: :post, where: as(:post).views > 1)
        end
        """

        diffs = diffs(src, mutators: @with_core)
        refute Enum.any?(diffs, fn {family, _, _} -> family in [:alias, :string, :tuple] end)
        assert {:ecto, "as(:post).views > 1", "as(:post).views >= 1"} in diffs
        assert_compiles(src, mutators: @with_core)
      end
    end

    test "route_arguments/2 uses the same source treatment for from and composable stages" do
      alias Mutare.CallRouting.{ArgumentRoutes, Call}

      piped_call = fn name, args, left ->
        Call.new(
          {name, [], args},
          Ecto.Query,
          name,
          {:piped, Sourceror.parse_string!(left)},
          fn new_name, new_args -> {new_name, [], new_args} end
        )
      end

      [clauses] = Sourceror.parse_string!("from(as: :post, where: as(:post).x > 1)") |> elem(2)
      from_routes = Host.Routing.route_arguments(piped_call.(:from, [clauses], "Post"), %{})
      assert ArgumentRoutes.piped(from_routes) == :raw
      assert ArgumentRoutes.visible(from_routes) == [{:keyword, [:raw, :hosted]}]

      [bindings, cond] = Sourceror.parse_string!("where([p], p.x > 1)") |> elem(2)

      where_routes =
        Host.Routing.route_arguments(piped_call.(:where, [bindings, cond], "query"), %{})

      assert ArgumentRoutes.piped(where_routes) == :expression
      assert ArgumentRoutes.visible(where_routes) == [:raw, :hosted]
    end
  end

  # The end-to-end tests above confirm delivery. The focused classifier checks below keep routing
  # shape failures easy to diagnose without manufacturing resolver metadata or bypassing the
  # public transform for mutation delivery.

  describe "treatments/3 — per-argument treatment" do
    # The classifier takes the resolved macro name, visible args, and pipe-left identity (what core reads
    # off a `Mutare.CallRouting.Call`); a snippet's own head and args stand in for them here, and
    # a `q |> macro(…)` snippet supplies `{:piped, left}` — its visible args exclude the query, as core's do.
    defp routing(code) do
      case Sourceror.parse_string!(code) do
        {:|>, _meta, [query, {name, _, args}]} ->
          Host.Routing.treatments(name, args, {:piped, query})

        {name, _meta, args} ->
          Host.Routing.treatments(name, args, :unpiped)
      end
    end

    test "from keyword form routes each binding condition independently" do
      assert routing("from(u in User, where: u.x == u.y, select: u.id)") ==
               [:raw, {:keyword, [:hosted, :raw]}]
    end

    test "from keyword form: a bindingless source routes where-shorthand values per-pair" do
      # The `where:` value is a keyword list → `{:keyword, [:interpolated]}` (core mutates the scalar,
      # `^`-pinned); `select:` is not a condition key → `:raw`. The order_by variant proves a
      # *non-condition* clause whose value is itself a keyword list still routes `:raw`, not the
      # condition treatment (pins the `key in @condition_keys` test, not just "has a kw value").
      assert routing(~s|from("users", where: [active: true], select: [:id])|) ==
               [:raw, {:keyword, [{:keyword, [:interpolated]}, :raw]}]

      assert routing(~s|from("t", where: [a: 1], order_by: [asc: :x])|) ==
               [:raw, {:keyword, [{:keyword, [:interpolated]}, :raw]}]

      assert routing(~s|from("users", select: [:id])|) == [:raw, {:keyword, [:raw]}]
    end

    test "from bare source: a named-binding condition hosts; shorthand still routes per-pair" do
      # A bare queryable (`from("posts", …)`) with an `as:` lets a `where:` reference a *named*
      # binding — a real SQL predicate, so the non-shorthand expression routes `:hosted` (the host
      # weaves an empty-binding `dynamic([], …)`), exactly as it would under a binding source. A
      # shorthand value is still plain data, routed per pair. The `as:`/`select:` keys stay raw.
      assert routing(~s|from("posts", as: :post, where: as(:post).views > 1, select: [:id])|) ==
               [:raw, {:keyword, [:raw, :hosted, :raw]}]

      assert routing(~s|from("posts", as: :post, where: [active: true], select: [:id])|) ==
               [:raw, {:keyword, [:raw, {:keyword, [:interpolated]}, :raw]}]
    end

    test "a piped from routes its one visible argument — the clause list — per clause" do
      # `Post |> from(…)`: the source is the `|>` left side (routed `:raw` by `route_arguments/2`,
      # not here — `treatments/3` covers the visible arguments only), so the clause list is
      # visible argument zero and routes exactly as the direct form's second argument does: the
      # named-binding condition `:hosted`, the literal bound `:hosted`, the shorthand per pair,
      # the data keys raw. Argless, there is nothing to route.
      assert routing("Post |> from(as: :post, where: as(:post).views > 1, limit: 5)") ==
               [{:keyword, [:raw, :hosted, :hosted]}]

      assert routing("Post |> from(where: [active: true], select: [:id])") ==
               [{:keyword, [{:keyword, [:interpolated]}, :raw]}]

      assert routing("Post |> from()") == []
      # A non-keyword clause argument stays raw, as in the direct form.
      assert routing("Post |> from(^clauses)") == [:raw]
    end

    test "from keyword form hosts a top-level interpolation (its interior is sub-contracted)" do
      # A top-level `where: ^cond` routes `:hosted` — its own SQL catalog is empty, but the host
      # hands the pin's Elixir interior to core (a pinned Elixir condition's logic is core's to
      # mutate), matching the standalone binding-form and free-standing `dynamic` paths.
      assert routing(~s|from(User, where: ^(x > 1))|) ==
               [:raw, {:keyword, [:hosted]}]
    end

    test "shorthand pair values: scalars pin, nil/interpolation/compound stay raw" do
      assert routing(~s|where(q, name: "x", age: 5, tag: :a, active: true)|) ==
               [
                 :expression,
                 {:keyword, [:interpolated, :interpolated, :interpolated, :interpolated]}
               ]

      # nil is an `IS NULL` (never `= nil`); `^v` is already interpolated; a list/field is compound
      # — all raw. (Pins scalar_literal?'s nil exclusion and pair_treatment.)
      assert routing(~s|where(q, a: nil, b: ^v, c: [1, 2], d: u.x)|) ==
               [:expression, {:keyword, [:raw, :raw, :raw, :raw]}]
    end

    test "condition macros (direct + piped) host the condition after the binding list" do
      assert routing("where(query, [u], u.x == u.y)") == [:expression, :raw, :hosted]
      assert routing("having(query, [u], u.x == u.y)") == [:expression, :raw, :hosted]
      assert routing("where(query, [post: p], p.x == p.y)") == [:expression, :raw, :hosted]
      assert routing("where(query, [u, post: p], p.x == u.y)") == [:expression, :raw, :hosted]
      # piped form — the binding list is the first *argument* (the query is the `|>` LHS).
      assert routing("q |> where([u], u.x == u.y)") == [:raw, :hosted]
      # a nested pipe as the first arg is the threaded query, like any expression.
      assert routing("where(q |> sub(), [u], u.x == u.y)") == [:expression, :raw, :hosted]
      # a `...`-anchored binding list is recognized too, so its condition routes `:hosted`.
      assert routing("where(query, [..., c], c.x == c.y)") == [:expression, :raw, :hosted]
    end

    test "a computed threaded query routes :expression — by form, not shape" do
      # Written directly, the first argument is the queryable whatever its shape: a function call
      # (`Ecto.Query.exclude/2` resolves to `Ecto.Query` yet is no query builder — it is still
      # the threaded query), a conditional, a map read. Core descends it as ordinary Elixir, so
      # `base_query(2)`'s `2` is mutated exactly as it is anywhere else.
      assert routing("where(base_query(2), [p], p.views > 1)") == [:expression, :raw, :hosted]

      assert routing("where(Ecto.Query.exclude(query, :order_by), [u], u.x == u.y)") ==
               [:expression, :raw, :hosted]

      assert routing("where(if(f, do: a, else: b), [u], u.x == u.y)") ==
               [:expression, :raw, :hosted]

      assert routing("select(Map.fetch!(queries, :a), [u], u.id)") == [:expression, :raw, :raw]
    end

    test "a structural queryable in the query slot stays raw" do
      # A schema alias, a table-name string (plain or interpolated), or a `{"table", Schema}` pair
      # names a table rather than computing a query; a swap there is a broken query, not a mutant.
      assert routing("where(Post, [p], p.views > 1)") == [:raw, :raw, :hosted]
      assert routing(~S|where("posts", [p], p.views > 1)|) == [:raw, :raw, :hosted]
      assert routing(~S|where("posts_#{shard}", [p], p.views > 1)|) == [:raw, :raw, :hosted]
      assert routing(~S|where({"posts", Post}, [p], p.views > 1)|) == [:raw, :raw, :hosted]
      assert routing("limit(Post, 10)") == [:raw, :hosted]
    end

    test "condition macro with no condition after the binding list hosts nothing" do
      # By arity, `Host.Condition.locate/3` reads a binding-only call's lone list as the condition,
      # not a declaration — and a list is never a hosted condition, so no position is `:hosted`.
      assert routing("q |> where([u])") == [:raw]
      assert routing("where(q, [u])") == [:expression, :raw]
    end

    test "a shorthand condition macro routes its trailing pairs per-pair" do
      assert routing("where(query, active: true)") == [:expression, {:keyword, [:interpolated]}]
    end

    test "plain clause macros thread the query and leave their data positions raw" do
      assert routing("order_by(query, [u], asc: u.x)") == [:expression, :raw, :raw]

      # the threaded query is whatever is written first — a bare var, a from(…), a pipe — each
      # → :expression.
      assert routing("select(q, [u], u.id)") == [:expression, :raw, :raw]
      assert routing("select(from(u in User), [u], u.id)") == [:expression, :raw, :raw]
      assert routing("select(q |> base(), [u], u.id)") == [:expression, :raw, :raw]
    end

    test "a literal bound routes :hosted (the pin-only bound bump); a non-literal stays raw" do
      assert routing("limit(query, 10)") == [:expression, :hosted]
      assert routing("offset(query, 5)") == [:expression, :hosted]
      # A pinned/expression bound has no literal to bump — raw, exactly as before.
      assert routing("limit(query, ^n)") == [:expression, :raw]
      assert routing("limit(query, n + 1)") == [:expression, :raw]
    end

    test "a piped clause macro's visible first argument is not the query" do
      # `q |> limit(10)`: the `10` is a bound — hosted for the pin-only bump, never `:expression`
      # (the threaded query is the `|>` left side, routed separately); the pipe mode says so, not
      # the argument's shape.
      assert routing("q |> limit(10)") == [:hosted]
      assert routing("q |> order_by(asc: :name)") == [:raw]
    end

    test "join routes its options per-pair, hosting the on: condition in direct and piped forms" do
      # The trailing options list routes like the `from` clause list: the `on:` value carries the
      # condition (`:hosted`, nested — core delivers a nested `:hosted` to `host/2` the same way),
      # every other option is data.
      assert routing("join(query, :inner, [u], p in Post, on: p.user_id == u.id)") ==
               [:expression, :raw, :raw, :raw, {:keyword, [:hosted]}]

      assert routing("q |> join(:inner, [u], p in Post, on: p.user_id == u.id)") ==
               [:raw, :raw, :raw, {:keyword, [:hosted]}]

      # An empty binding list is a written declaration too (the on-condition references no prior
      # binding); the trailing `on:` still routes per-pair with its `:hosted` condition, and the
      # host re-declares `[..., p]`.
      assert routing("join(query, :inner, [], p in Post, on: p.views > 1)") ==
               [:expression, :raw, :raw, :raw, {:keyword, [:hosted]}]

      # A non-`on:` option is never the condition, whatever it sits next to.
      assert routing("join(query, :inner, [u], p in Post, as: :p, on: p.user_id == u.id)") ==
               [:expression, :raw, :raw, :raw, {:keyword, [:raw, :hosted]}]
    end

    test "a join's keyword-shorthand on: routes its pairs, like the from form's" do
      # `on: [views: 5]` is data, not an SQL fragment — the host's catalog reads conditions, so
      # routing the whole options list `:hosted` would leave the `5` unmutated by *everything*.
      # Per-pair routing hands it to core's literal families, `^`-pinned.
      assert routing("join(query, :inner, [u], p in Post, on: [views: 5])") ==
               [:expression, :raw, :raw, :raw, {:keyword, [{:keyword, [:interpolated]}]}]

      # The same nil/compound exclusions the `where` shorthand applies (`pair_treatment/1`).
      assert routing("join(query, :inner, [u], p in Post, on: [views: nil, id: u.id])") ==
               [:expression, :raw, :raw, :raw, {:keyword, [{:keyword, [:raw, :raw]}]}]
    end

    test "join with no on: key at all keeps its trailing options raw" do
      # Per-pair routing with no condition among the pairs: every value `:raw`, keys raw — the
      # same "nothing here is mutable" answer the whole-argument `:raw` gave.
      assert routing("join(query, :inner, [u], p in Post, as: :p)") ==
               [:expression, :raw, :raw, :raw, {:keyword, [:raw]}]

      # No trailing keyword list at all — the base routing stands.
      assert routing("join(query, :inner, [u], p in Post)") ==
               [:expression, :raw, :raw, :raw]
    end

    test "a non-routing macro yields []" do
      assert routing("foobar(query, 1)") == []
    end

    test "a clause-less from(Post) routes :skip (nothing to host)" do
      assert routing("from(Post)") == [:raw]
    end

    test "a from with a malformed (non-list) second argument routes it :skip" do
      # `rest` is `[clauses]` for the ordinary `from(source, kw)` shape; a non-list single trailing
      # argument is malformed AST that still routes `:raw`, same as a clause-less `from(Post)` —
      # but unlike the clause-less case (`rest = []`, where `List.duplicate(_, 0)` never places the
      # computed value in the output at all), this shape actually has one position to fill, so it's
      # the one that observes what the fallback branch's value actually is.
      assert routing("from(Post, :not_a_list)") == [:raw, :raw]
    end

    test "an empty list is neither a binding list nor a shorthand keyword list" do
      # `[]` must not be mistaken for a binding list (so the `[]` slot itself is never `:hosted`) nor
      # for shorthand pairs (so it never becomes a `{:keyword, …}` overlay) — it is a raw data arg.
      assert routing("where(q, [])") == [:expression, :raw]
    end

    test "an empty binding list still hosts the condition that follows it (binding-less)" do
      # `where(q, [], cond)` ≡ `where(q, cond)`: the explicit `[]` declares no positional binding, so
      # the trailing condition is the binding-less hosted form (woven `dynamic([], …)`). The `[]`
      # slot stays raw; only the condition routes `:hosted`. (A condition written here can only
      # reference *named* bindings — `as(:_)` — which the empty-binding dynamic resolves.)
      assert routing("where(q, [], as(:post).x == as(:post).y)") == [:expression, :raw, :hosted]
    end
  end

  describe "the recorded diff is a clean logical change" do
    test "a standalone named binding produces live hosted mutations" do
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(p in "posts", as: :post)
          |> where([post: p], p.age > 18)
        end
      end
      """

      assert {"p.age > 18", "p.age >= 18"} in ecto_diffs(src)
      assert metamutant(src) =~ "dynamic([post: p]"
      assert_compiles(src)
    end

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

    test "a condition weave and both bound weaves ride one from as independent targets" do
      # Three hosted targets on a single macro call — the condition (dynamic-wrapped) plus two
      # pin-only bounds. Each weaves its own selector into its own position, and only the three
      # structural drops (where/limit/offset) still copy the query.
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(p in "posts", where: p.x > 1, limit: 10, offset: 2, select: p.id)
      end
      """

      diffs = ecto_diffs(src)

      assert {"p.x > 1", "p.x >= 1"} in diffs

      for pair <- [{"10", "11"}, {"10", "9"}, {"2", "3"}, {"2", "1"}] do
        assert pair in diffs
      end

      mm = metamutant(src)
      assert mm =~ ~r/where:\s*\^case/
      assert mm =~ ~r/limit:\s*\^case/
      assert mm =~ ~r/offset:\s*\^case/
      # baseline + 3 drop mutants — no per-bump (or per-swap) copies.
      assert length(String.split(mm, "from(")) - 1 == 4

      assert_compiles(src)
    end

    test "a bound bump's diff is the bare integers — no pin/case scaffolding either" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from(u in User, limit: 10, select: u.id)
      end
      """

      # The pin-only weave (`limit: ^(case …)`) reports only the logical pair; the drop is the
      # sole whole-`from` diff.
      bumps = hosted(src)
      assert Enum.sort(bumps) == [{"10", "11"}, {"10", "9"}]

      for {original, mutated} <- bumps, code <- [original, mutated] do
        refute code =~ "case"
        refute code =~ "^"
      end
    end
  end
end

defmodule Mutare.Ecto.HostTest.Runtime do
  # Sync: this module runs a metamutant, and the selector that picks its branch is global
  # (`Mutare.Ecto.SelectorSyncTest`).
  use ExUnit.Case, async: false

  import Mutare.Ecto.TestSupport

  # The source for one enumerated join pattern (see the oracle tests): a named join is
  # `join: cN in "comments"` with an `on:` against `p`, and an unnamed join a bare
  # `cross_join: "audit"`. `"audit"` and `"comments"` share their column names, so a misplaced slot
  # still compiles. The `where:`s — one per named join — follow *all* the joins, as they would be
  # written: Ecto applies a `from`'s clauses in written order and resolves a `^dynamic` against the
  # query built so far, so an `on:` is resolved with only the joins up to its own in place, but
  # these `where:`s with every join in place — including an unnamed one *after* the join they name.
  defp slot_pattern_source(module, source, pattern) do
    numbered = Enum.with_index(pattern, 1)

    joins =
      Enum.map_join(numbered, "\n", fn
        {true, n} -> ~s(      join: c#{n} in "comments",\n      on: c#{n}.post_id == p.id,)
        {false, _n} -> ~s(      cross_join: "audit",)
      end)

    wheres =
      for {true, n} <- numbered, into: "", do: "      where: c#{n}.score > 10,\n"

    """
    defmodule #{module} do
      import Ecto.Query

      def base, do: from(p in "posts", left_join: u in "users", on: u.id == p.user_id)

      def q do
        from p in #{source},
    #{joins}
    #{wheres}      where: p.id > 0,
          select: p.id
      end
    end
    """
  end

  # The oracle for binding *positions*, independent of how the host computes them: Ecto itself.
  # `source_for.(module_name)` renders a fixture exposing `q/0`. The untouched source is compiled
  # here under a name unique to this test (the metamutant gets its own from core's wrapper), since
  # `Code.compile_string` defines modules globally. A hosted condition is woven as
  # `^dynamic(bindings, condition)`, which Ecto resolves to binding indices when it builds the
  # query — so if the re-declared list is faithful, the metamutant's baseline builds the very query
  # the untouched source does, and `inspect/1` (which renders every reference by index:
  # `c2.score`) reads identically. A dropped or misplaced slot shows up as a different index
  # (`a1.score`), however plausible the SQL.
  #
  # Returns the build's hosted `{original, mutated}` pairs, for the caller to check that the
  # comparison was not vacuous — read from the sites of the build under test, not from a second
  # transform of the same source.
  defp assert_baseline_builds_original(source_for) do
    original = Module.concat(__MODULE__, :"SlotOracle#{System.unique_integer([:positive])}")
    [{^original, _binary} | _] = Code.compile_string(source_for.(inspect(original)))

    on_exit(fn ->
      :code.purge(original)
      :code.delete(original)
    end)

    {[woven], sites} = Mutare.Test.compile_metamutant(source_for.("Q"), mutators([]))

    # The baseline is pinned, not assumed: the ambient selection is a global another test may
    # have left at a mutant, and an unpinned `woven.q()` would then build that mutant's query.
    baseline = Mutare.Test.with_active_mutant(0, fn -> woven.q() end)
    assert inspect(baseline) == inspect(original.q())

    # A hosted mutant always rewrites to non-empty text; a clause drop is a deletion
    # (`HostTest`'s `hosted/1`).
    for %{mutator: :ecto, mutated_code: mutated} = site <- sites,
        mutated != "",
        do: {site.original_code, mutated}
  end

  defp assert_pattern_baseline_builds_original(source, pattern) do
    conditions = assert_baseline_builds_original(&slot_pattern_source(&1, source, pattern))

    # Every condition was in fact hosted.
    assert {"p.id > 0", "p.id >= 0"} in conditions

    for {true, n} <- Enum.with_index(pattern, 1) do
      assert {"c#{n}.post_id == p.id", "c#{n}.post_id != p.id"} in conditions
      assert {"c#{n}.score > 10", "c#{n}.score >= 10"} in conditions
    end
  end

  describe "binding extraction — the woven baseline, built by Ecto" do
    # Positions checked against Ecto itself (`assert_baseline_builds_original/1`). Every
    # named/unnamed pattern of one to three joins is enumerated — which covers an unnamed join
    # before, between, and after named ones, several in a row, and none at all — over a literal
    # and a composed source (whose hidden join makes the `...` anchor load-bearing).
    join_patterns =
      for length <- 1..3,
          pattern <-
            Enum.reduce(1..length, [[]], fn _, acc ->
              for p <- acc, n <- [true, false], do: [n | p]
            end),
          do: pattern

    for {source_kind, source} <- [literal: ~s("posts"), composed: "base()"],
        pattern <- join_patterns do
      label = Enum.map_join(pattern, ", ", &if(&1, do: "named", else: "unnamed"))

      test "baseline builds the original query — #{source_kind} source, joins: #{label}" do
        assert_pattern_baseline_builds_original(unquote(source), unquote(pattern))
      end
    end

    # Positions checked against Ecto itself, as for the `from` form. `base/0` hides a second
    # binding, so `...` has something to skip and a misplaced `x` reads a different table.
    for {label, bindings, condition} <- [
          {"a written `...` list", "[..., x]", "x.score > 10"},
          {"a leading positional", "[p]", "p.id > 1"},
          {"a full written list", "[p, x]", "x.score > p.id"},
          {"an empty list", "[]", "as(:c).score > 10"}
        ] do
      test "baseline builds the original query — standalone unnamed join, #{label}" do
        source_for = fn module ->
          """
          defmodule #{module} do
            import Ecto.Query

            def base,
              do: from(p in "posts", join: c in "comments", as: :c, on: c.post_id == p.id)

            def q do
              base()
              |> join(:inner, #{unquote(bindings)}, "audit", on: #{unquote(condition)})
              |> select([p], p.id)
            end
          end
          """
        end

        conditions = assert_baseline_builds_original(source_for)

        assert Enum.any?(conditions, fn {original, _mutated} ->
                 original == unquote(condition)
               end)
      end
    end
  end
end
