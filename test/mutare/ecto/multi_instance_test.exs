defmodule Mutare.Ecto.MultiInstanceTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The headline configuration story: **list the plugin twice**. Per the `:as` convention
  # (consumed by core, never reaching the plugin), two instances split the catalog into
  # separately-named report families, or report two repos separately (one entry with
  # `repo: [A, B]` covers both under one name — `config_test.exs`) — each instance parses its own
  # `families:`/`repo:` via `init/1` and filters through its own `finalize/2` funnel. These are
  # the only tests exercising two live instances at once; everything else runs one. The sharp
  # edges: an instance must never record a family outside its own selection (else the split
  # double-fires the shared surface — both instances are offered every node and host every
  # subscribed macro), and each instance's sites must carry *its* report name.

  describe "a families:/as: split (two instances over the same query surface)" do
    @src """
    defmodule M do
      import Ecto.Query
      def q, do: from(u in User, where: u.age > 18, limit: 10, select: u.id)
    end
    """

    @split [
      {Mutare.Ecto, repo: MyApp.Repo, families: [:comparison], as: :ecto_cmp},
      {Mutare.Ecto, repo: MyApp.Repo, families: {:default, except: [:comparison]}}
    ]

    test "each family records under its instance's report name" do
      sites = sites(@src, mutators: @split)

      # The comparison swap belongs to the renamed instance…
      assert [comparison] = Enum.filter(sites, &(&1.mutated_code =~ "u.age >= 18"))
      assert comparison.mutator == :ecto_cmp

      # …while the complementary instance keeps everything else under the default name: the
      # in-fragment literal bump, the hosted bound bump, and the whole-`from` drops.
      assert [literal] = Enum.filter(sites, &(&1.mutated_code =~ "u.age > 19"))
      assert literal.mutator == :ecto

      assert [bump] = Enum.filter(sites, &(&1.mutated_code == "11"))
      assert bump.mutator == :ecto

      drops = Enum.filter(sites, &(&1.mutated_code == ""))
      assert drops != []
      assert Enum.all?(drops, &(&1.mutator == :ecto))
    end

    test "the split never double-fires: the two selections partition the mutant set" do
      sites = sites(@src, mutators: @split)

      # No logical mutant appears under both instances (same range, same rendering)…
      keys = Enum.map(sites, &{&1.range, &1.mutated_code})
      assert Enum.uniq(keys) == keys

      # …and the split's union equals the single-instance default run, site for site — renames
      # aside, splitting the catalog must not add, drop, or duplicate a mutant.
      merged =
        sites |> Enum.map(&{&1.range, &1.original_code, &1.mutated_code}) |> Enum.sort()

      single =
        @src
        |> sites()
        |> Enum.map(&{&1.range, &1.original_code, &1.mutated_code})
        |> Enum.sort()

      assert merged == single
    end
  end

  describe "a per-repo report split (two instances with their own repo: and as:)" do
    test "each instance covers exactly its own repo's calls" do
      src = """
      defmodule M do
        def a(q), do: MyApp.RepoA.aggregate(q, :sum, :age)
        def b(q), do: MyApp.RepoB.aggregate(q, :sum, :age)
      end
      """

      sites =
        sites(src,
          mutators: [
            {Mutare.Ecto, repo: MyApp.RepoA, as: :repo_a},
            {Mutare.Ecto, repo: MyApp.RepoB, as: :repo_b}
          ]
        )

      # One aggregate swap per repo, each under its own report name — instance A never fires on
      # RepoB's call and vice versa.
      assert [a] = Enum.filter(sites, &(&1.mutator == :repo_a))
      assert a.mutated_code =~ "RepoA.aggregate(q, :avg, :age)"

      assert [b] = Enum.filter(sites, &(&1.mutator == :repo_b))
      assert b.mutated_code =~ "RepoB.aggregate(q, :avg, :age)"

      assert length(sites) == 2
    end
  end
end
