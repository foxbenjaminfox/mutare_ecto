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

    test "a `^dynamic` operand is left raw — the host weaves nothing" do
      # The condition is a pre-built dynamic interpolated with `^`: Ecto's own composition primitive,
      # mutated where it is defined, not in the fragment. No `dynamic(` scaffolding is woven (the one
      # mutation is the orthogonal stage drop).
      src = """
      defmodule M do
        import Ecto.Query
        def q(query, filter), do: query |> where(^filter)
      end
      """

      refute metamutant(src) =~ "dynamic("
      assert_compiles(src)
    end

    test "a top-level interpolation in a from clause is left outside the SQL host" do
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

    test "a top-level interpolation stays raw alongside a hosted bare-source condition" do
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

  # The end-to-end tests above confirm delivery. The focused classifier checks below keep routing
  # shape failures easy to diagnose without manufacturing resolver metadata or bypassing the
  # public transform for mutation delivery.

  describe "treatments/1 — per-argument treatment" do
    defp routing(code), do: code |> Sourceror.parse_string!() |> Host.Routing.treatments()

    test "from keyword form routes each binding condition independently" do
      assert routing("from(u in User, where: u.x == u.y, select: u.id)") ==
               [:skip, {:keyword, [:hosted, :skip]}]
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

    test "from bare source: a named-binding condition hosts; shorthand still routes per-pair" do
      # A bare queryable (`from("posts", …)`) with an `as:` lets a `where:` reference a *named*
      # binding — a real SQL predicate, so the non-shorthand expression routes `:hosted` (the host
      # weaves an empty-binding `dynamic([], …)`), exactly as it would under a binding source. A
      # shorthand value is still plain data, routed per pair. The `as:`/`select:` keys stay raw.
      assert routing(~s|from("posts", as: :post, where: as(:post).views > 1, select: [:id])|) ==
               [:skip, {:keyword, [:skip, :hosted, :skip]}]

      assert routing(~s|from("posts", as: :post, where: [active: true], select: [:id])|) ==
               [:skip, {:keyword, [:skip, {:keyword, [:pinned]}, :skip]}]
    end

    test "from keyword form leaves a top-level interpolation raw" do
      assert routing(~s|from(User, where: ^(x > 1))|) ==
               [:skip, {:keyword, [:skip]}]
    end

    test "shorthand pair values: scalars pin, nil/interpolation/compound stay raw" do
      assert routing(~s|where(q, name: "x", age: 5, tag: :a, active: true)|) ==
               [:expression, {:keyword, [:pinned, :pinned, :pinned, :pinned]}]

      # nil is an `IS NULL` (never `= nil`); `^v` is already interpolated; a list/field is compound
      # — all raw. (Pins scalar_literal?'s nil exclusion and pair_treatment.)
      assert routing(~s|where(q, a: nil, b: ^v, c: [1, 2], d: u.x)|) ==
               [:expression, {:keyword, [:skip, :skip, :skip, :skip]}]
    end

    test "condition macros (direct + piped) host the condition after the binding list" do
      assert routing("where(query, [u], u.x == u.y)") == [:expression, :skip, :hosted]
      assert routing("having(query, [u], u.x == u.y)") == [:expression, :skip, :hosted]
      assert routing("where(query, [post: p], p.x == p.y)") == [:expression, :skip, :hosted]
      assert routing("where(query, [u, post: p], p.x == u.y)") == [:expression, :skip, :hosted]
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

    test "join hosts the trailing on option in direct and piped forms" do
      assert routing("join(query, :inner, [u], p in Post, on: p.user_id == u.id)") ==
               [:expression, :skip, :skip, :skip, :hosted]

      assert routing("join(:inner, [u], p in Post, on: p.user_id == u.id)") ==
               [:skip, :skip, :skip, :hosted]
    end

    test "a non-routing macro yields []" do
      assert routing("foobar(query, 1)") == []
    end

    test "an empty list is neither a binding list nor a shorthand keyword list" do
      # `[]` must not be mistaken for a binding list (so the `[]` slot itself is never `:hosted`) nor
      # for shorthand pairs (so it never becomes a `{:keyword, …}` overlay) — it is a raw data arg.
      assert routing("where(q, [])") == [:expression, :skip]
    end

    test "an empty binding list still hosts the condition that follows it (binding-less)" do
      # `where(q, [], cond)` ≡ `where(q, cond)`: the explicit `[]` declares no positional binding, so
      # the trailing condition is the binding-less hosted form (woven `dynamic([], …)`). The `[]`
      # slot stays raw; only the condition routes `:hosted`. (A condition written here can only
      # reference *named* bindings — `as(:_)` — which the empty-binding dynamic resolves.)
      assert routing("where(q, [], as(:post).x == as(:post).y)") == [:expression, :skip, :hosted]
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
  end
end
