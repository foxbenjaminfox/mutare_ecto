defmodule Mutare.EctoTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "the installed Ecto release is in the supported range" do
    version = :ecto |> Application.spec(:vsn) |> to_string()

    assert Version.match?(version, "~> 3.12"),
           "expected Ecto >= 3.12 and < 4.0, got #{version}"
  end

  describe "ensure_ecto!/1 (the startup guard for the deployment requirement)" do
    test "passes when the Ecto surface is loadable, as it is when run inside the app under test" do
      assert Mutare.Ecto.ensure_ecto!() == :ok
    end

    test "an external-source run — the Ecto surface not on the code path — fails loudly, naming the missing module" do
      assert_raise RuntimeError, ~r/No\.Such\.Ecto.*dependency\s+of the app under test/s, fn ->
        Mutare.Ecto.ensure_ecto!([Ecto.Query, No.Such.Ecto])
      end
    end

    test "registration runs the guard: macro_routes/0 and hosted_macros/0 both pass through it" do
      # The positive path — both callbacks call `ensure_ecto!/0` before building their entries,
      # so an external-source run fails at registration, not mid-transform.
      assert [_ | _] = Mutare.Ecto.macro_routes()
      assert [_ | _] = Mutare.Ecto.hosted_macros()
    end
  end

  describe "macro_routes/0" do
    test "skips schema, routes the host macros and the clause macros, skips dynamic" do
      macros = Mutare.Ecto.macro_routes()

      # Schema bodies are never mutated.
      assert {Ecto.Schema, :schema, :skip} in macros
      assert {Ecto.Schema, :embedded_schema, :skip} in macros

      # The `from` opener and the where/having family route through the selector host
      # (`:routing` → `route_arguments/2` → `host/2`).
      assert {Ecto.Query, :from, :any, :routing} in macros
      assert {Ecto.Query, :where, :any, :routing} in macros
      assert {Ecto.Query, :or_where, :any, :routing} in macros
      assert {Ecto.Query, :having, :any, :routing} in macros
      assert {Ecto.Query, :or_having, :any, :routing} in macros

      # The plain clause macros also route (`:routing`) so the threaded query is mutated as an
      # expression (not suppressed) and the stage can be dropped (`Mutare.Ecto.ClauseDrop`).
      assert {Ecto.Query, :order_by, :any, :routing} in macros
      assert {Ecto.Query, :select, :any, :routing} in macros
      assert {Ecto.Query, :limit, :any, :routing} in macros
      assert {Ecto.Query, :join, :any, :routing} in macros

      # `dynamic` is an in-fragment helper, not a query-threading stage, so it stays :skip.
      assert {Ecto.Query, :dynamic, :any, :skip} in macros
    end

    test "classifies every macro exported by the supported Ecto.Query version" do
      registered =
        Mutare.Ecto.macro_routes()
        |> Enum.flat_map(fn
          {Ecto.Query, name, _treatment} -> [name]
          {Ecto.Query, name, _arity, _treatment} -> [name]
          _other -> []
        end)
        |> MapSet.new()

      exported = Ecto.Query.__info__(:macros) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      assert MapSet.subset?(exported, registered),
             "unclassified Ecto.Query macros: #{inspect(MapSet.difference(exported, registered))}"
    end

    test "an omitted query macro cannot leak core mutations into its binding list" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: prepend_order_by(query, [u], asc: u.id)
      end
      """

      all = [:all, {Mutare.Ecto, repo: MyApp.Repo}]

      refute Enum.any?(diffs(src, mutators: all), fn {mutator, original, _mutated} ->
               mutator in [:list, :atom] and original in ["[u]", "asc:"]
             end)

      assert {"prepend_order_by(query, [u], asc: u.id)", "query"} in ecto_diffs(src)

      assert_compiles(src, mutators: all)
    end
  end

  describe "schema skip" do
    test "a use Ecto.Schema body yields a compilable metamutant" do
      src = """
      defmodule MySchema do
        use Ecto.Schema

        schema "posts" do
          field :title, :string
          field :views, :integer
        end
      end
      """

      assert_compiles(src, mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}])
    end
  end

  describe "query skip prevents poison" do
    test "core never splices a selector into a where condition; the metamutant compiles" do
      src = """
      defmodule Posts do
        import Ecto.Query
        def popular, do: from(p in "posts", where: p.views > 10, select: p.id)
      end
      """

      mutators = [:all, {Mutare.Ecto, repo: MyApp.Repo}]

      # The `>` inside the where is never mutated in place (it would poison): Relational
      # must not have fired. The whole-query families (Ecto where-drop, ReturnValue) still do.
      refute Enum.any?(diffs(src, mutators: mutators), fn {mutator, _o, _m} ->
               mutator == :relational
             end)

      assert_compiles(src, mutators: mutators)
    end
  end
end
