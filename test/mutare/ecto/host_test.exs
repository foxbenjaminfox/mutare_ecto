defmodule Mutare.Ecto.HostTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

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

    test "named source rebinds sort after positional joins (dynamic/2 requires named binds last)" do
      # Regression: a query that rebinds *named* sources up front and adds a *positional* join after
      # establishes bindings in the order `[source: s, file: f, j]` — but `Ecto.Query.dynamic/2`
      # requires `{as, var}` named binds to be **last** and raises at macro-expansion otherwise. The
      # woven dynamic must reorder to positional-first, named-last (`[j, source: s, file: f]`), or the
      # metamutant won't compile. `assert_compiles` is the real guard here — the bug was a compile-
      # time `Ecto.Query.CompileError`, not a runtime one.
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

      assert metamutant(src) =~ "dynamic([j, source: s, file: f]"
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
