defmodule Mutare.EctoTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  describe "macros/0" do
    test "registers schema and the query macros as :skip" do
      macros = Mutare.Ecto.macros()

      assert {Ecto.Schema, :schema, :skip} in macros
      assert {Ecto.Schema, :embedded_schema, :skip} in macros
      assert {Ecto.Query, :from, :any, :skip} in macros
      assert {Ecto.Query, :where, :any, :skip} in macros
      assert {Ecto.Query, :order_by, :any, :skip} in macros
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

      mm = metamutant(src, mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}])
      assert compiles?(mm)
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

      sites = sites(src, mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}])
      mm = metamutant(src, mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}])

      # The `>` inside the where is never mutated in place (it would poison): Relational
      # must not have fired. The whole-query families (Ecto where-drop, ReturnValue) still do.
      refute Enum.any?(sites, &(&1.mutator == :relational))
      assert compiles?(mm)
    end
  end

  # Compile a rendered metamutant in this process to prove compile-safety, then unload it.
  defp compiles?(source) do
    source
    |> Code.compile_string()
    |> Enum.each(fn {mod, _bin} ->
      :code.purge(mod)
      :code.delete(mod)
    end)

    true
  rescue
    error ->
      flunk("metamutant failed to compile: #{Exception.message(error)}\n\n#{source}")
  end
end
