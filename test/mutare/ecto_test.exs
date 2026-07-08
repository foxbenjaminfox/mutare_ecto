defmodule Mutare.EctoTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "the installed Ecto release is in the supported range" do
    version = :ecto |> Application.spec(:vsn) |> to_string()

    assert Version.match?(version, "~> 3.12"),
           "expected Ecto >= 3.12 and < 4.0, got #{version}"
  end

  describe "required_modules/0 (the declared deployment requirement)" do
    # Core checks the declaration once at startup — `Mutare.Mutator.Spec` resolution runs
    # `Mutare.EnvironmentError.verify!/1` before `init/1` — so an external-source run (the Ecto
    # surface not on the code path) aborts with a `Mutare.EnvironmentError` before any source is
    # read, instead of silently registering routes against nothing. The missing-module path and
    # message are core's own (covered by core's environment tests); here we pin what the plugin
    # *declares* and that the declaration passes inside the app under test.
    test "declares the Ecto surface the routing registers against" do
      assert Mutare.Ecto.required_modules() == [Ecto.Schema, Ecto.Query]
    end

    test "passes core's environment check when run inside the app under test" do
      assert Mutare.EnvironmentError.verify!(Mutare.Ecto) == :ok
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

    test "a registered clause macro shields its binding/keyword list from core's list/atom families" do
      # `prepend_order_by` *is* a registered `:routing` clause macro (see the exhaustive
      # registration check above) — so its binding list `[u]` and keyword key `asc:` are DSL data
      # kept raw, never reachable by core's `:list`/`:atom` mutators, while the plugin's own
      # ordering flip still fires on it.
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

      # `prepend_order_by` is routed and mutated (its direction flip fires); it is not
      # stage-droppable, so there is no `"query"` collapse.
      assert {"prepend_order_by(query, [u], asc: u.id)",
              "prepend_order_by(query, [u], desc: u.id)"} in ecto_diffs(src)

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
