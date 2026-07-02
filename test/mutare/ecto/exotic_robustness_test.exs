defmodule Mutare.Ecto.ExoticRobustnessTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # The single-build net over the *whole* exotic surface: every snippet here is valid, exotic
  # Ecto, and each is pushed through the transform under three configurations —
  #
  #   1. the plugin's defaults,
  #   2. every family (the opt-in literal arms included) under the widest dialect set, and
  #   3. the plugin *plus all of core's mutators* (the full production shape),
  #
  # asserting the rendered metamutant compiles each time. `Mutare.Test.assert_metamutant_compiles`
  # embeds every recorded mutant behind the selector, so this catches the two catastrophic
  # failure modes at once: a transform crash on a node shape the plugin has never seen, and a
  # single mutant that poisons the build (a selector spliced into a query position, a dangling
  # adjacency-checked keyword, a rewrite Ecto rejects at expansion). Behaviour-precise
  # assertions live in `exotic_query_test.exs`; this file is breadth.

  @plugin_all [
    mutators: [{Mutare.Ecto, repo: MyApp.Repo, families: :all, dialects: [:postgres, :mysql]}]
  ]
  @with_core [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo, families: :all}]]

  @corpus [
    kitchen_sink_from: """
    defmodule C do
      import Ecto.Query

      def q(min_age, roles) do
        from u in MyApp.User,
          as: :user,
          join: p in assoc(u, :posts),
          as: :posts,
          left_join: o in MyApp.Post,
          on: o.user_id == u.id and o.published == true,
          where: u.age > ^min_age and u.role in ^roles,
          where: fragment("lower(?)", u.name) != "root",
          or_where: coalesce(u.score, 0) >= 10 and not is_nil(u.joined_at),
          where: u.joined_at > ago(2, "year") and field(u, :age) < 120,
          group_by: u.id,
          having: filter(count(p.id), p.views > 0) > 1,
          order_by: [asc_nulls_last: u.score, desc: selected_as(:post_count)],
          offset: 5,
          limit: 10,
          with_ties: true,
          select: %{id: u.id, post_count: selected_as(count(p.id), :post_count)}
      end
    end
    """,
    window_shop: """
    defmodule C do
      import Ecto.Query

      def q do
        from p in MyApp.Post,
          windows: [
            by_user: [partition_by: p.user_id, order_by: [desc: p.views]],
            global: [order_by: p.id]
          ],
          select: %{
            id: p.id,
            rank: over(rank(), :by_user),
            dense: over(dense_rank(), :global),
            prev: over(lag(p.views, 1), :by_user),
            next: over(lead(p.views, 1), :by_user),
            share: over(sum(p.views), partition_by: p.user_id) + over(avg(p.views), :global)
          }
      end
    end
    """,
    recursive_cte: """
    defmodule C do
      import Ecto.Query

      def q do
        initial = from(p in MyApp.Post, where: is_nil(p.user_id), select: %{id: p.id})

        recursion =
          from(p in MyApp.Post,
            join: t in "tree",
            on: p.user_id == t.id,
            select: %{id: p.id}
          )

        tree = union_all(initial, ^recursion)

        "tree"
        |> recursive_ctes(true)
        |> with_cte("tree", as: ^tree)
        |> select([t], t.id)
      end
    end
    """,
    update_query_zoo: """
    defmodule C do
      import Ecto.Query

      def promote(ids) do
        from(p in MyApp.Post,
          join: u in MyApp.User,
          on: u.id == p.user_id,
          where: p.id in ^ids and u.active == true,
          update: [set: [published: true], inc: [views: 1]]
        )
        |> MyApp.Repo.update_all([])
      end

      def retitle do
        MyApp.Post
        |> where([p], is_nil(p.title))
        |> update([p], set: [title: "untitled"])
        |> MyApp.Repo.update_all([])
      end

      def prune do
        MyApp.Repo.delete_all(from p in MyApp.Post, where: p.views == 0)
      end
    end
    """,
    values_sources: """
    defmodule C do
      import Ecto.Query

      def q(entries) do
        from v in values(entries, %{id: :integer, weight: :integer}),
          where: v.weight > 0,
          select: v.id
      end

      def q2 do
        from v in values([%{id: 1, weight: 2}, %{id: 3, weight: 4}], %{id: :integer, weight: :integer}),
          join: p in MyApp.Post,
          on: p.id == v.id,
          where: p.views >= v.weight,
          select: {p.id, v.weight}
      end
    end
    """,
    json_paths: """
    defmodule C do
      import Ecto.Query

      def q(key) do
        from p in MyApp.Post,
          where: p.title["tags"][0]["name"] == "elixir",
          where: json_extract_path(p.title, ["meta", "flags", 1]) == true,
          where: p.title[^key] != "hidden",
          select: %{first_tag: p.title["tags"][0], flag: json_extract_path(p.title, [^key])}
      end
    end
    """,
    fragment_zoo: """
    defmodule C do
      import Ecto.Query

      def q(col, vals, pattern) do
        from p in MyApp.Post,
          where: like(fragment("lower(?)", fragment("trim(?)", p.title)), ^pattern),
          where: fragment("? IN ?", p.views, splice(^vals)),
          where: fragment("? > 0", identifier(^col)),
          where: fragment(title: [foo: "bar"]) == true,
          group_by: fragment("date(?)", p.title),
          order_by: fragment("random()"),
          select: %{n: fragment("count(?)", literal(^col)), d: fragment("date(?)", p.title)}
      end
    end
    """,
    dynamic_zoo: """
    defmodule C do
      import Ecto.Query

      def filters(min, max, published?) do
        base = dynamic([p], p.views > ^min and p.views < ^max)
        base = if published?, do: dynamic([p], ^base and p.published == true), else: base
        negated = dynamic([p], not (^base))
        bindingless = dynamic(^negated)
        named = dynamic([posts: p], p.views >= ^min)

        from p in MyApp.Post,
          as: :posts,
          where: ^bindingless,
          or_where: ^named,
          order_by: ^[desc: dynamic([p], coalesce(p.views, 0))]
      end
    end
    """,
    changeset_zoo: """
    defmodule C do
      import Ecto.Changeset

      def changeset(user, attrs) do
        user
        |> cast(attrs, [:name, :age, :role])
        |> cast_assoc(:posts, with: &post_changeset/2)
        |> validate_required([:name])
        |> validate_change(:age, fn :age, age ->
          if age < 0, do: [age: "must be non-negative"], else: []
        end)
        |> validate_number(:age, greater_than_or_equal_to: 0, less_than: 150)
        |> validate_inclusion(:role, ["admin", "user"])
        |> update_change(:name, &String.trim/1)
        |> put_change(:active, true)
        |> unique_constraint(:name, name: :users_name_index)
        |> check_constraint(:age, name: :age_must_be_positive)
        |> prepare_changes(fn changeset -> changeset end)
        |> optimistic_lock(:age)
      end

      def post_changeset(post, attrs) do
        post
        |> cast(attrs, [:title, :views])
        |> validate_required([:title])
        |> put_assoc(:user, nil)
      end
    end
    """,
    schemaless_zoo: """
    defmodule C do
      import Ecto.Query

      def q do
        from p in "posts",
          prefix: "analytics",
          where: p.views > 10 and p.category in ["a", "b", "c"],
          select: %{id: p.id, title: p.title},
          limit: 5
      end

      def q2 do
        from(p in {"archived_posts", MyApp.Post}, where: p.published == false, select: map(p, [:id]))
      end

      def bump do
        MyApp.Repo.update_all(from(p in "posts", where: p.views < 0, update: [set: [views: 0]]), [])
      end
    end
    """,
    combination_zoo: """
    defmodule C do
      import Ecto.Query

      def q do
        popular = from p in MyApp.Post, where: p.views > 100, select: p.id
        published = from p in MyApp.Post, where: p.published == true, select: p.id
        drafts = from p in MyApp.Post, where: p.published == false, select: p.id

        popular
        |> union(^published)
        |> union_all(^drafts)
        |> intersect(^published)
        |> except_all(^drafts)
        |> intersect_all(^popular)
        |> except(^published)
      end
    end
    """,
    pipe_manipulation_zoo: """
    defmodule C do
      import Ecto.Query

      def q(base) do
        base
        |> exclude(:order_by)
        |> reverse_order()
        |> or_where([p], p.views == 0)
        |> prepend_order_by([p], asc: p.id)
        |> distinct([p], p.user_id)
        |> lock("FOR UPDATE")
      end

      def q2(base) do
        if has_named_binding?(base, :posts) do
          with_named_binding(base, :posts, &where(&1, [posts: p], p.views > 1))
        else
          base
        end
      end
      def where_views(q), do: where(q, [p], p.views > 2)
    end
    """,
    aggregate_zoo: """
    defmodule C do
      import Ecto.Query

      def q do
        from p in MyApp.Post,
          group_by: p.user_id,
          having: count(p.id, :distinct) > 1 and sum(p.views) / count(p.id) >= 10,
          having: max(p.views) - min(p.views) > 5,
          select: %{
            user: p.user_id,
            distinct_titles: count(p.title, :distinct),
            spread: max(p.views) - min(p.views),
            mean: sum(p.views) / count(p.id)
          }
      end
    end
    """,
    terminal_and_repo_zoo: """
    defmodule C do
      import Ecto.Query

      def newest, do: MyApp.Post |> order_by(asc: :id) |> last(:id) |> MyApp.Repo.one()
      def oldest, do: MyApp.Post |> first(:id) |> MyApp.Repo.one(timeout: 1000)

      def stats do
        %{
          count: MyApp.Repo.aggregate(MyApp.Post, :count),
          max: MyApp.Repo.aggregate(MyApp.Post, :max, :views, timeout: 5000),
          any?: MyApp.Repo.exists?(from p in MyApp.Post, where: p.views > 0)
        }
      end

      def all_with_opts(q), do: MyApp.Repo.all(q, prefix: "main", timeout: 30_000)
    end
    """,
    temporal_zoo: """
    defmodule C do
      import Ecto.Query

      def q(interval) do
        from u in MyApp.User,
          where: u.joined_at > ago(1, "month") and u.joined_at < from_now(1, "day"),
          where: u.joined_at > datetime_add(^NaiveDateTime.utc_now(), -3, "week"),
          where: u.joined_at < datetime_add(^NaiveDateTime.utc_now(), ^interval, "hour"),
          select: u.id
      end
    end
    """,
    literal_zoo: """
    defmodule C do
      import Ecto.Query

      def q do
        from u in MyApp.User,
          where: u.age > -1 and u.age != 0,
          where: u.score > 2.5 or u.score < -0.5,
          where: u.role in ["admin", "ops"] and u.role not in [~s(guest)],
          where: u.active == true and u.name != "",
          where: u.age * 2 + 1 - 3 > 10,
          select: {u.id, "constant", 42, 3.14, true, :tagged}
      end
    end
    """,
    author_macro_zoo: """
    defmodule CHelpers do
      defmacro recent(column, days) do
        quote do
          unquote(column) > ago(unquote(days), "day")
        end
      end
    end

    defmodule C do
      import Ecto.Query
      import CHelpers

      def q do
        from u in MyApp.User,
          where: recent(u.joined_at, 7) and u.active == true
      end
    end
    """
  ]

  for {name, source} <- @corpus do
    test "#{name}: metamutant compiles under plugin defaults" do
      assert_compiles(unquote(source))
    end

    test "#{name}: metamutant compiles with every family and dialect enabled" do
      assert_compiles(unquote(source), @plugin_all)
    end

    test "#{name}: metamutant compiles alongside all of core's mutators" do
      assert_compiles(unquote(source), @with_core)
    end

    test "#{name}: sites are unique, non-identity, and range-faithful" do
      assert_site_invariants(unquote(source))
    end
  end

  # Structural invariants over every site the production shape (plugin + core) records — generic
  # nets for failure modes no behaviour-precise test can enumerate:
  #
  #   * **no duplicate mutants** — two sites sharing a range and mutated rendering are one logical
  #     mutant delivered twice (the double-delivery failure mode: a mutation produced by two
  #     paths, e.g. an old `mutate/2` producer surviving a migration to the host, or core reaching
  #     a position the plugin also owns);
  #   * **no identity mutants** — a mutant that renders identically to its original compiles,
  #     runs, and "survives" while testing nothing, silently corrupting the score;
  #   * **range fidelity** — a single-line site's recorded range must slice exactly the source
  #     text the site claims to mutate, or reports and `# mutare:ignore` (matched by the site's
  #     line) anchor to the wrong code. Multi-line sites are skipped: their `original_code` is a
  #     re-render, not a source slice.
  defp assert_site_invariants(source) do
    %Mutare.Transform.Result{mutants: sites} =
      Mutare.transform_string(source,
        file: "robustness_invariants.ex",
        mutators: mutators(@with_core),
        expand_uses: true
      )

    assert sites != [], "expected the fixture to produce mutants"

    duplicates =
      sites
      |> Enum.group_by(&{&1.range, &1.mutated_code})
      |> Enum.filter(fn {_key, group} -> length(group) > 1 end)

    assert duplicates == [],
           "duplicate mutants (same range, same rendering):\n" <>
             inspect(duplicates, pretty: true)

    for site <- sites do
      refute site.original_code == site.mutated_code,
             "identity mutant at #{site.file}:#{site.line} (#{site.mutator}): " <>
               inspect(site.original_code)
    end

    lines = String.split(source, "\n")

    # The repeated `line` variable makes the generator itself select single-line sites (a
    # multi-line or absent range fails the match and is skipped, not raised on). The comparison
    # is modulo whitespace, parens, and commas — same tokens, so a range anchored to the *wrong*
    # code still fails — because two cosmetic classes are legitimate: a clause site's range may
    # include the keyword list's trailing comma (core derives the end from Sourceror's
    # `end_of_expression` meta), and a paren-less `from p in …` re-renders as `from(p in …)` in
    # `original_code`.
    for %{range: %{start: %{line: line, column: sc}, end: %{line: line, column: ec}}} = site <-
          sites do
      slice = lines |> Enum.at(line - 1) |> String.slice(sc - 1, ec - sc)

      assert tokens(slice) == tokens(site.original_code),
             "site #{site.id} (#{site.mutator}) at line #{line} records " <>
               inspect(site.original_code) <> " but its range slices " <> inspect(slice)
    end
  end

  defp tokens(code), do: String.replace(code, ~r/[\s(),]+/, "")
end
