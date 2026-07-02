defmodule Mutare.Ecto.MacroSkipTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # A user can define their own macros and use them *inside* an Ecto `where`/`having` fragment. When
  # they register such a macro `:skip` (or some of its arguments `:skip`), the plugin must leave that
  # argument opaque rather than mutating into the body the author owns — the SQL the macro expands to
  # is the author's, not the catalog's to rewrite. The plugin honours this by reading each nested
  # call's resolved per-argument routing (`Mutare.Calls.macro_treatment/1`, stamped by the
  # resolve pre-pass) as `Mutare.Ecto.Fragment`/`Mutare.Ecto.Aggregate` walk the hosted condition.
  #
  # `MyApp.QueryHelpers` supplies the author macros and `MyApp.QueryHelperMutator` registers their
  # routing; adding that mutator to `:mutators` is how a real library would ship the registration.
  # Every test pins the contrast: the same source *without* the registration still mutates into the
  # macro, so each assertion shows the skip is what suppresses it (not some unrelated gap).
  #
  # `families: :all` turns on the opt-in literal arms (string/atom/boolean) too, so the partial-skip
  # test can pin that an atom in a `:skip` position is left raw *even when atom mutation is enabled*.

  @base_mutators [{Mutare.Ecto, repo: MyApp.Repo, families: :all}]
  @helper_mutators [{Mutare.Ecto, repo: MyApp.Repo, families: :all}, MyApp.QueryHelperMutator]

  # The set of *mutated* renderings the host delivers (the in-fragment `^`/`dynamic` mutations),
  # dropping the whole-`from` query rewrites (which mention `from(`), exactly as `HostTest` does.
  # `opts` is forwarded to `Mutare.transform_string/2` — the config-channel test threads
  # `:macro_routes` through it, which core's `Mutare.Test.diffs_for/3` cannot carry.
  defp hosted_mutateds(source, mutators, opts \\ []) do
    result = Mutare.transform_string(source, [{:mutators, mutators} | opts])

    for site <- result.mutants,
        site.mutator == :ecto,
        not String.starts_with?(site.original_code, "from("),
        into: MapSet.new(),
        do: site.mutated_code
  end

  describe "a fully :skip-registered nested macro" do
    test "is left opaque — its in-fragment literals are not mutated" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q, do: from(u in User, where: between(u.age, 18, 65))
      end
      """

      # Unregistered, the catalog descends into the call and mutates both literal bounds.
      bare = hosted_mutateds(src, @base_mutators)
      assert "between(u.age, 19, 65)" in bare
      assert "between(u.age, 18, 64)" in bare

      # Registered `:skip`, the whole call is opaque, so no bound is mutated and the host weaves
      # nothing into this `where` at all.
      assert hosted_mutateds(src, @helper_mutators) == MapSet.new()
      assert_compiles(src, mutators: @helper_mutators)
    end
  end

  describe "a partially-routed nested macro (`[:expression, :skip]`)" do
    test "mutates the :expression argument but leaves the :skip argument raw" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q, do: from(u in User, where: tagged(u.age > 18, :urgent))
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      # The :expression argument (the condition) still mutates under SQL semantics...
      assert "tagged(u.age >= 18, :urgent)" in muts
      assert "tagged(u.age > 19, :urgent)" in muts

      # ...while the :skip argument (the trailing label) is never the AtomLiteral sentinel, even with
      # atom mutation enabled.
      refute "tagged(u.age > 18, :mutare)" in muts

      # Without the registration that atom *is* mutated — the contrast that isolates the skip.
      assert "tagged(u.age > 18, :mutare)" in hosted_mutateds(src, @base_mutators)

      assert_compiles(src, mutators: @helper_mutators)
    end
  end

  describe "the Aggregate swap inside a hosted having" do
    test "does not reach an aggregate wrapped in a :skip-registered macro" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q do
          from p in Post,
            group_by: p.user_id,
            having: clamp(sum(p.views), 10) > 5,
            select: p.user_id
        end
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      # The condition's own comparison and the un-wrapped literal still mutate...
      assert "clamp(sum(p.views), 10) >= 5" in muts
      assert "clamp(sum(p.views), 10) > 6" in muts

      # ...but the aggregate and bound *inside* the opaque `clamp` are untouched.
      refute "clamp(avg(p.views), 10) > 5" in muts
      refute "clamp(sum(p.views), 11) > 5" in muts

      # Without the registration both the aggregate swap and the inner bound appear.
      bare = hosted_mutateds(src, @base_mutators)
      assert "clamp(avg(p.views), 10) > 5" in bare
      assert "clamp(sum(p.views), 11) > 5" in bare

      assert_compiles(src, mutators: @helper_mutators)
    end
  end

  # The cases above all flow through the `from(..., where:/having:)` keyword DSL (`Host.from_targets`).
  # The standalone/pipe condition macros reach the host by a *different* door (`Host.condition_target`,
  # with bindings read from the written `[u]` list), so they get their own coverage. These anchor on a
  # sibling condition that *does* mutate rather than an empty set, since a standalone clause's drop
  # rewrite — unlike a whole-`from`'s — is not filtered by the `from(` guard.
  describe "the standalone and piped condition macros" do
    test "a direct where(q, [u], cond) leaves a nested :skip macro opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q(query), do: where(query, [u], between(u.age, 18, 65) and u.score > 5)
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      # The un-wrapped sibling comparison still mutates; the :skip macro's bound does not.
      assert "between(u.age, 18, 65) and u.score >= 5" in muts
      refute "between(u.age, 19, 65) and u.score > 5" in muts

      # Without the registration the macro's bound mutates too — the contrast.
      assert "between(u.age, 19, 65) and u.score > 5" in hosted_mutateds(src, @base_mutators)

      assert_compiles(src, mutators: @helper_mutators)
    end

    test "a piped q |> where([u], cond) leaves a nested :skip macro opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q(query), do: query |> where([u], between(u.age, 18, 65) and u.score > 5)
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      assert "between(u.age, 18, 65) and u.score >= 5" in muts
      refute "between(u.age, 19, 65) and u.score > 5" in muts

      assert "between(u.age, 19, 65) and u.score > 5" in hosted_mutateds(src, @base_mutators)

      assert_compiles(src, mutators: @helper_mutators)
    end

    test "a piped having([u], cond) leaves a :skip macro wrapping an aggregate opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q(query), do: query |> having([u], clamp(sum(u.age), 10) > 5)
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      # The condition's own comparison still swaps; the aggregate inside the opaque `clamp` does not.
      assert "clamp(sum(u.age), 10) >= 5" in muts
      refute "clamp(avg(u.age), 10) > 5" in muts

      # Without the registration the wrapped aggregate swaps too.
      assert "clamp(avg(u.age), 10) > 5" in hosted_mutateds(src, @base_mutators)

      assert_compiles(src, mutators: @helper_mutators)
    end
  end

  # A join's `on:` condition hosts through yet another door (`Host.JoinOn` gates it, since Ecto only
  # accepts a `^dynamic` as a join's *sole, top-level* on-expression), reached two ways: the `on:` key
  # of a `from`'s `join:` clause (`Host.from_targets`) and the trailing `on:` option of a standalone
  # `join/5` call (`Host.join_target`). Both walk the on-condition through the shared catalog, so both
  # must honour a nested `:skip` macro. Each anchors on the sibling comparison that *does* mutate.
  describe "the join `on:` condition path" do
    test "a from(..., join:, on:) keyword clause leaves a nested :skip macro opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q do
          from u in User,
            join: p in Post,
            on: between(p.views, 1, 100) and p.user_id == u.id,
            select: u.id
        end
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      # The on-condition's own comparison still swaps; the :skip macro's bounds do not.
      assert "between(p.views, 1, 100) and p.user_id != u.id" in muts
      refute "between(p.views, 2, 100) and p.user_id == u.id" in muts

      # Without the registration the macro's bound mutates too — the contrast.
      assert "between(p.views, 2, 100) and p.user_id == u.id" in hosted_mutateds(
               src,
               @base_mutators
             )

      assert_compiles(src, mutators: @helper_mutators)
    end

    test "a standalone join(:inner, [u], p in S, on:) leaves a nested :skip macro opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q(query) do
          query
          |> join(:inner, [u], p in Post, on: between(p.views, 1, 100) and p.user_id == u.id)
        end
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      assert "between(p.views, 1, 100) and p.user_id != u.id" in muts
      refute "between(p.views, 2, 100) and p.user_id == u.id" in muts

      assert "between(p.views, 2, 100) and p.user_id == u.id" in hosted_mutateds(
               src,
               @base_mutators
             )

      assert_compiles(src, mutators: @helper_mutators)
    end
  end

  # A binding reorder is delivered **in place** — it swaps the written binding list, never the
  # condition body. So when a `:skip` macro spans both bindings, the reorder still fires (it's a real,
  # safe mutation) by transposing the list, and the macro's argument source is left exactly as the
  # author wrote it. This is what makes reordering safe across an opaque macro: we never need to
  # rewrite — or even understand — the macro's arguments.
  describe "a binding reorder across a :skip macro" do
    test "swaps the binding list in place and never the :skip macro's argument source" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q(query), do: where(query, [a, b], between(a.age, 18, b.score))
      end
      """

      muts = hosted_mutateds(src, @helper_mutators)

      # The reorder swaps the declared list; the body (the `:skip` macro call) rides along verbatim.
      assert Enum.any?(muts, &(&1 =~ "where(query, [b, a], between(a.age, 18, b.score))"))

      # The macro's arguments are never rewritten — no `a`/`b` reference swap reaches into the body…
      refute Enum.any?(muts, &(&1 =~ "between(b.age, 18, a.score)"))
      # …and `:skip` still suppresses the literal bound inside the opaque macro.
      refute Enum.any?(muts, &(&1 =~ "between(a.age, 19"))

      assert_compiles(src, mutators: @helper_mutators)
    end
  end

  # Everything above registers the routing the way a *library* ships it — a provider module
  # (`MyApp.QueryHelperMutator`) listed in `:mutators`. An end user writes the same skip
  # *declaratively*, via the `:macro_routes` option (`{module, name, arity, :skip}` in config).
  # Both channels funnel into the same registry and the same resolve-pass stamp — a config entry
  # even overrides a code-provided route — so the hosted walkers cannot tell them apart. But the
  # configuration story is its own public surface, so it gets its own pin: the same source with
  # *no* provider mutator anywhere, the skip supplied purely by configuration.
  describe "the declarative `:macro_routes` config channel" do
    @config_routes [{MyApp.QueryHelpers, :between, 3, :skip}]

    test "a config-registered :skip is honored inside a hosted where" do
      src = """
      defmodule M do
        import Ecto.Query
        import MyApp.QueryHelpers
        def q, do: from(u in User, where: between(u.age, 18, 65) and u.score > 5)
      end
      """

      # Without the config entry, the catalog descends into the call and mutates its bounds.
      assert "between(u.age, 19, 65) and u.score > 5" in hosted_mutateds(src, @base_mutators)

      # With only the declarative entry, the macro is opaque: the sibling comparison still
      # mutates, while neither bound inside the skipped call ever does.
      muts = hosted_mutateds(src, @base_mutators, macro_routes: @config_routes)
      assert "between(u.age, 18, 65) and u.score >= 5" in muts
      refute "between(u.age, 19, 65) and u.score > 5" in muts
      refute "between(u.age, 18, 64) and u.score > 5" in muts

      # The single-build net still holds with the route applied. `assert_compiles` cannot thread
      # `:macro_routes` (core's `assert_metamutant_compiles/2` takes only mutators), so use the
      # option-forwarding `Mutare.Test.compile_metamutant/3` directly.
      assert {[_ | _], _sites} =
               Mutare.Test.compile_metamutant(src, @base_mutators, macro_routes: @config_routes)
    end
  end
end
