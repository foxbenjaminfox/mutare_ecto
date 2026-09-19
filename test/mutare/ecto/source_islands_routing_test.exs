defmodule Mutare.Ecto.SourceIslandsRoutingTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "computed subquery sources honor resolved routes in both spellings" do
    for inner <- ["limit(build(2), 3)", "build(2) |> limit(3)"],
        condition <- ["exists(#{inner})", "p.id in subquery(#{inner})"] do
      source = """
      defmodule Q do
        import Ecto.Query
        def build(n), do: from(MyApp.Post, limit: ^n)
        def q, do: from(p in MyApp.Post, where: #{condition})
      end
      """

      for {route, source_mutated?} <- [
            {{Ecto.Query, :limit, :skip}, false},
            {{Ecto.Query, :limit, 2, :raw}, false},
            {{Ecto.Query, :limit, 2, [:raw, :expression]}, false},
            {{Ecto.Query, :limit, 2, [:expression, :raw]}, true}
          ] do
        opts = [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}], call_routes: [route]]

        actual =
          Enum.any?(diffs(source, opts), fn {family, _, mutated} ->
            family == :integer and mutated =~ "build(3)"
          end)

        assert actual == source_mutated?, "#{condition} with route #{inspect(route)}"
        assert_compiles(source, opts)
      end
    end
  end
end
