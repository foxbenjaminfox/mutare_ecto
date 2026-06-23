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

    test "a keyword-shorthand where carries no hosted dynamic and no sites" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, active: true)
      end
      """

      assert diffs(src) == []
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

    test "like/ilike is woven and compiles" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(pat), do: from(u in User, where: like(u.name, ^pat), select: u.id)
      end
      """

      assert Enum.any?(hosted(src), fn {_o, mutated} -> mutated == "ilike(u.name, ^pat)" end)
      assert_compiles(src)
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
