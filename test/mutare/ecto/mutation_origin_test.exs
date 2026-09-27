defmodule Mutare.Ecto.MutationOriginTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  @mutators [
    {Mutare.Mutators.Arithmetic, as: :math},
    {Mutare.Ecto, families: [:comparison, :integer_literal, :coalesce, :membership]}
  ]

  # Exercise real Ecto delivery as well as the report: each patch must build the
  # same query as the corresponding selected branch, including the baseline.
  for query <- [
        ~s|from(p in "posts", where: p.score > ^(n * 2) and p.id not in [1, 2])|,
        ~s|where("posts", [p], ^dynamic([p], p.score > ^(n * 2)))|,
        ~s|where("posts", [{p, 0 + 0}], p.score > ^(n * 2))|,
        ~s|from(p in "posts", where: is_nil(coalesce(p.score, 2)))|,
        ~s|from(p in "posts", where: p.score > ^(n * 2) and p.views < ^(n + 1))|
      ] do
    test "reported patches match selected queries: #{query}" do
      source = """
      defmodule Q do
        import Ecto.Query
        def q(n), do: #{unquote(query)}
      end
      """

      {[instrumented], sites} = Mutare.Test.compile_metamutant(source, @mutators)
      assert sites != []

      for site <- [nil | sites] do
        patched =
          if site,
            do: Sourceror.patch_string(source, [%{range: site.range, change: site.mutated_code}]),
            else: source

        {[reference], []} = Mutare.Test.compile_metamutant(patched, [])

        for n <- [0, 3] do
          actual =
            Mutare.Test.with_active_mutant(if(site, do: site.id, else: 0), fn ->
              inspect(instrumented.q(n))
            end)

          assert actual == inspect(reference.q(n)),
                 "query differs for #{inspect(site && {site.original_code, site.mutated_code})}"
        end
      end
    end
  end

  test "identical island expressions on different lines suppress independently" do
    source = """
    defmodule Q do
      import Ecto.Query
      def q(n) do
        from(p in "posts",
          where:
            p.score > ^(n * 2) and # mutare:ignore[math:/]
              p.views > ^(n * 2)
        )
      end
    end
    """

    sites = sites(source, mutators: @mutators)
    assert [first, second] = Enum.filter(sites, &(&1.mutator == :math))
    assert {first.line, second.line} == {6, 7}
    assert first.ignored
    refute second.ignored
    assert first.original_code == second.original_code
    assert first.mutated_code == second.mutated_code
    assert first.original_code == "n * 2"
    assert first.mutated_code == "n / 2"
    assert Enum.any?(sites, &(&1.mutator == :ecto and not &1.ignored))
  end

  test "an inner SQL comparison keeps its line, note and suppression through two pins" do
    source = """
    defmodule Q do
      import Ecto.Query
      def q do
        where("posts", [p],
          ^dynamic([p],
            ^dynamic([p],
              p.score > 10 and # mutare:ignore[ecto:comparison]
                p.views > 20
            )
          )
        )
      end
    end
    """

    sites = assert_builds(source, & &1.q(), mutators: [{Mutare.Ecto, families: [:comparison]}])
    assert [first, second] = sites
    assert {first.line, second.line} == {7, 8}
    assert {first.original_code, first.mutated_code} == {"p.score > 10", "p.score >= 10"}
    assert {second.original_code, second.mutated_code} == {"p.views > 20", "p.views >= 20"}
    assert first.ignored
    refute second.ignored
    assert first.note =~ "kill may require"
    assert second.note == first.note
  end
end
