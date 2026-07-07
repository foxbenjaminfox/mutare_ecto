defmodule Mutare.Ecto.MacroSkipTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  alias Mutare.Test.Fixtures.RoutingExtension

  # A user can define their own macros and use them *inside* an Ecto `where`/`having` fragment. When
  # they register such a macro `:skip` (or some of its arguments `:skip`), the plugin must leave that
  # argument opaque rather than mutating into the body the author owns — the SQL the macro expands to
  # is the author's, not the catalog's to rewrite. The plugin honours this by reading each nested
  # call's resolved per-argument routing (`Mutare.Calls.macro_treatment/1`, stamped by the
  # resolve pre-pass) as `Mutare.Ecto.Fragment`/`Mutare.Ecto.Aggregate` walk the hosted condition.
  #
  # The author macros and their routing come from core's shipped routing-only fixture,
  # `Mutare.Test.Fixtures.RoutingExtension` — `opaque/1` (fully `:skip`) and `tagged/2`
  # (`[:expression, :skip]`) — enabled through the `:extensions` channel, exactly how an independent
  # library ships the registration its DSL relies on. Routing applies only when the extension is
  # enabled, so every test pins the contrast: the same source *without* it still mutates into the
  # macro, showing the skip is what suppresses it (not some unrelated gap).
  #
  # `families: :all` turns on the opt-in literal arms (string/atom/boolean) too, so the partial-skip
  # test can pin that an atom in a `:skip` position is left raw *even when atom mutation is enabled*.

  @mutators [{Mutare.Ecto, repo: MyApp.Repo, families: :all}]
  @routing [RoutingExtension]

  # The set of *mutated* renderings the host delivers (the in-fragment `^`/`dynamic` mutations),
  # dropping the whole-`from` query rewrites. Those rewrites now report at their inner clause: a
  # filter_drop/bound-drop is a clause-level DELETE (`mutated == ""`), so we drop the empty-delete
  # diffs (a hosted condition mutation always renders a non-empty replacement, so this hides a
  # legitimate clause drop without masking a real hosted regression). `opts` rides through
  # `Mutare.Ecto.TestSupport.diffs/2` to `Mutare.transform_string/2`, so the routed cases thread
  # `extensions:` (and the config-channel test `:macro_routes`) alongside `:mutators`.
  defp hosted_mutateds(source, opts) do
    for {mutator, _original, mutated} <- diffs(source, opts),
        mutator == :ecto,
        mutated != "",
        into: MapSet.new(),
        do: mutated
  end

  describe "a fully :skip-registered nested macro" do
    test "is left opaque — its in-fragment condition is not mutated" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q, do: from(u in User, where: opaque(u.age > 18))
      end
      """

      # Unregistered, the catalog descends into the call and mutates the wrapped condition.
      bare = hosted_mutateds(src, mutators: @mutators)
      assert "opaque(u.age >= 18)" in bare
      assert "opaque(u.age > 19)" in bare

      # Registered `:skip`, the whole call is opaque, so nothing inside is mutated and the host
      # weaves nothing into this `where` at all.
      assert hosted_mutateds(src, mutators: @mutators, extensions: @routing) == MapSet.new()
      assert_compiles(src, mutators: @mutators, extensions: @routing)
    end
  end

  describe "a partially-routed nested macro (`[:expression, :skip]`)" do
    test "mutates the :expression argument but leaves the :skip argument raw" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q, do: from(u in User, where: tagged(u.age > 18, :urgent))
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      # The :expression argument (the condition) still mutates under SQL semantics...
      assert "tagged(u.age >= 18, :urgent)" in muts
      assert "tagged(u.age > 19, :urgent)" in muts

      # ...while the :skip argument (the trailing label) is never the AtomLiteral sentinel, even with
      # atom mutation enabled.
      refute "tagged(u.age > 18, :mutare)" in muts

      # Without the registration that atom *is* mutated — the contrast that isolates the skip.
      assert "tagged(u.age > 18, :mutare)" in hosted_mutateds(src, mutators: @mutators)

      assert_compiles(src, mutators: @mutators, extensions: @routing)
    end
  end

  describe "the Aggregate swap inside a hosted having" do
    test "does not reach an aggregate wrapped in a :skip-registered macro" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q do
          from p in Post,
            group_by: p.user_id,
            having: opaque(sum(p.views)) > 5,
            select: p.user_id
        end
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      # The condition's own comparison and its literal still mutate...
      assert "opaque(sum(p.views)) >= 5" in muts
      assert "opaque(sum(p.views)) > 6" in muts

      # ...but the aggregate *inside* the opaque call is untouched.
      refute "opaque(avg(p.views)) > 5" in muts

      # Without the registration the aggregate swap appears.
      assert "opaque(avg(p.views)) > 5" in hosted_mutateds(src, mutators: @mutators)

      assert_compiles(src, mutators: @mutators, extensions: @routing)
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
        import Mutare.Test.Fixtures.RoutingExtension
        def q(query), do: where(query, [u], opaque(u.age > 18) and u.score > 5)
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      # The un-wrapped sibling comparison still mutates; the :skip macro's condition does not.
      assert "opaque(u.age > 18) and u.score >= 5" in muts
      refute "opaque(u.age > 19) and u.score > 5" in muts

      # Without the registration the macro's condition mutates too — the contrast.
      assert "opaque(u.age > 19) and u.score > 5" in hosted_mutateds(src, mutators: @mutators)

      assert_compiles(src, mutators: @mutators, extensions: @routing)
    end

    test "a piped q |> where([u], cond) leaves a nested :skip macro opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q(query), do: query |> where([u], opaque(u.age > 18) and u.score > 5)
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      assert "opaque(u.age > 18) and u.score >= 5" in muts
      refute "opaque(u.age > 19) and u.score > 5" in muts

      assert "opaque(u.age > 19) and u.score > 5" in hosted_mutateds(src, mutators: @mutators)

      assert_compiles(src, mutators: @mutators, extensions: @routing)
    end

    test "a piped having([u], cond) leaves a :skip macro wrapping an aggregate opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q(query), do: query |> having([u], opaque(sum(u.age)) > 5)
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      # The condition's own comparison still swaps; the aggregate inside the opaque call does not.
      assert "opaque(sum(u.age)) >= 5" in muts
      refute "opaque(avg(u.age)) > 5" in muts

      # Without the registration the wrapped aggregate swaps too.
      assert "opaque(avg(u.age)) > 5" in hosted_mutateds(src, mutators: @mutators)

      assert_compiles(src, mutators: @mutators, extensions: @routing)
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
        import Mutare.Test.Fixtures.RoutingExtension
        def q do
          from u in User,
            join: p in Post,
            on: opaque(p.views > 1) and p.user_id == u.id,
            select: u.id
        end
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      # The on-condition's own comparison still swaps; the :skip macro's condition does not.
      assert "opaque(p.views > 1) and p.user_id != u.id" in muts
      refute "opaque(p.views > 2) and p.user_id == u.id" in muts

      # Without the registration the macro's condition mutates too — the contrast.
      assert "opaque(p.views > 2) and p.user_id == u.id" in hosted_mutateds(src,
               mutators: @mutators
             )

      assert_compiles(src, mutators: @mutators, extensions: @routing)
    end

    test "a standalone join(:inner, [u], p in S, on:) leaves a nested :skip macro opaque" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q(query) do
          query
          |> join(:inner, [u], p in Post, on: opaque(p.views > 1) and p.user_id == u.id)
        end
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      assert "opaque(p.views > 1) and p.user_id != u.id" in muts
      refute "opaque(p.views > 2) and p.user_id == u.id" in muts

      assert "opaque(p.views > 2) and p.user_id == u.id" in hosted_mutateds(src,
               mutators: @mutators
             )

      assert_compiles(src, mutators: @mutators, extensions: @routing)
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
        import Mutare.Test.Fixtures.RoutingExtension
        def q(query), do: where(query, [a, b], opaque(a.age > b.score))
      end
      """

      muts = hosted_mutateds(src, mutators: @mutators, extensions: @routing)

      # The reorder swaps the declared list; the body (the `:skip` macro call) rides along verbatim.
      assert Enum.any?(muts, &(&1 =~ "where(query, [b, a], opaque(a.age > b.score))"))

      # The macro's arguments are never rewritten — no `a`/`b` reference swap reaches into the body…
      refute Enum.any?(muts, &(&1 =~ "opaque(b.age > a.score)"))
      # …and `:skip` still suppresses the comparison inside the opaque macro.
      refute Enum.any?(muts, &(&1 =~ "opaque(a.age >= b.score)"))

      assert_compiles(src, mutators: @mutators, extensions: @routing)
    end
  end

  # Everything above registers the routing the way an independent *library* ships it — a routing
  # extension listed under `:extensions`. An end user writes the same skip *declaratively*, via the
  # `:macro_routes` option (`{module, name, arity, :skip}` in config). Both channels funnel into the
  # same registry and the same resolve-pass stamp — a config entry even overrides a code-provided
  # route — so the hosted walkers cannot tell them apart. But the configuration story is its own
  # public surface, so it gets its own pin: the same source with *no* extension anywhere, the skip
  # supplied purely by configuration.
  describe "the declarative `:macro_routes` config channel" do
    @config_routes [{RoutingExtension, :opaque, 1, :skip}]

    test "a config-registered :skip is honored inside a hosted where" do
      src = """
      defmodule M do
        import Ecto.Query
        import Mutare.Test.Fixtures.RoutingExtension
        def q, do: from(u in User, where: opaque(u.age > 18) and u.score > 5)
      end
      """

      # Without the config entry, the catalog descends into the call and mutates its condition.
      assert "opaque(u.age > 19) and u.score > 5" in hosted_mutateds(src, mutators: @mutators)

      # With only the declarative entry, the macro is opaque: the sibling comparison still
      # mutates, while nothing inside the skipped call ever does.
      muts = hosted_mutateds(src, mutators: @mutators, macro_routes: @config_routes)
      assert "opaque(u.age > 18) and u.score >= 5" in muts
      refute "opaque(u.age > 19) and u.score > 5" in muts
      refute "opaque(u.age >= 18) and u.score > 5" in muts

      # The single-build net still holds with the route applied — `assert_compiles` forwards
      # `:macro_routes` to the transform, like every other option.
      assert_compiles(src, mutators: @mutators, macro_routes: @config_routes)
    end
  end
end
