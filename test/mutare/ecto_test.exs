defmodule Mutare.EctoTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  describe "macros/0" do
    test "skips schema, routes the host macros and the clause macros, skips dynamic" do
      macros = Mutare.Ecto.macros()

      # Schema bodies are never mutated.
      assert {Ecto.Schema, :schema, :skip} in macros
      assert {Ecto.Schema, :embedded_schema, :skip} in macros

      # The `from` opener and the where/having family route through the selector host
      # (`:routing` → `macro_routing/1` → `host/2`).
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
