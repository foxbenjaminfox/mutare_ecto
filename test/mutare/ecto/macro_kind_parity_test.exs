defmodule Mutare.Ecto.MacroKindParityTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  alias Mutare.Ecto.{Host, Surface}

  # Three dispatch loops switch independently on `Surface.macro_kind/1`'s closed taxonomy, and
  # each ends in a catch-all that silently yields nothing:
  #
  #   * `Mutare.Ecto.Dispatcher.query_macro_mutations/3` — which sub-mutators see the whole call
  #   * `Mutare.Ecto.Host.host/2` — which hosted-target builder weaves the call
  #   * `Mutare.Ecto.Host.Routing.route_macro/4` — how core treats each argument position
  #     (`:from` short-circuits earlier, in `treatments/3`'s dedicated clause)
  #
  # The catch-alls are correct for today's inert cases (`:raw`-kind macros, and `nil` for a name
  # the plugin doesn't own), but Elixir has no exhaustiveness check: add or rename a kind in
  # `Surface` and any of the three can silently degrade a whole macro family to "no mutations" —
  # for a mutation-testing tool, silent coverage loss, the worst failure mode. This is the
  # taxonomy-level cousin of `fragment_descent_test.exs` (the condition walk's descent policy):
  # every kind in
  # `Surface.macro_kinds/0` must carry a probe below, and each probe pins observable evidence
  # that all three loops take a real branch for that kind — or that the kind is *structurally*
  # excluded from a loop (registered `:raw`, so core never calls `route_arguments/2`; absent
  # from `hosted_macro_names/0`, so the host is never offered the call), which is stronger than
  # trusting the catch-all.
  #
  # Each probe:
  #
  #   * `representative` — a macro name whose descriptor carries the kind, re-asserted per test
  #     so a Surface rename fails here by name, not silently downstream
  #   * `fixture` — one source whose transform exercises the kind end to end
  #   * `dispatcher` — diff pairs only `query_macro_mutations/3`'s branch for the kind can
  #     record (stage drops, clause deletions, whole-call rewrites — the host's targets are
  #     always in-place swaps/bumps, never deletions or whole-call rewrites), or
  #     `:deliberately_empty`
  #   * `hosted` — diff pairs only the host's weave delivers (in-condition operator swaps and
  #     bound bumps — no `mutate/2` sub-mutator emits those), or `:never_subscribed`
  #   * `routing` — `{snippet, expected}` for `Host.Routing.treatments/3` (every probe is a
  #     direct call, so `:unpiped`), whose
  #     position-specific answer (a `:hosted` overlay) proves the kind matched a real routing
  #     branch rather than the `[]` catch-all, or `:registered_raw`
  @probes %{
    from: %{
      representative: :from,
      fixture: """
      defmodule Posts do
        import Ecto.Query
        def q, do: from(p in "posts", where: p.x > 1, select: p.id)
      end
      """,
      # The whole-`from` filter drop (`Query.mutations` via the dispatcher's `:from` branch),
      # reported as a deletion at the dropped clause.
      dispatcher: [{"p.x > 1", ""}],
      # The in-fragment comparison swap — delivered only by the host's `from_targets` weave.
      hosted: [{"p.x > 1", "p.x >= 1"}],
      routing:
        {~s|from(p in "posts", where: p.x > 1, select: p.id)|,
         [:raw, {:keyword, [:hosted, :raw]}]}
    },
    condition: %{
      representative: :where,
      fixture: """
      defmodule Posts do
        import Ecto.Query
        def q(query), do: where(query, [u], u.x == u.y)
      end
      """,
      # The stage drop (`ClauseDrop` via the dispatcher's `:condition` branch).
      dispatcher: [{"where(query, [u], u.x == u.y)", "query"}],
      hosted: [{"u.x == u.y", "u.x != u.y"}],
      routing: {"where(query, [u], u.x == u.y)", [:expression, :raw, :hosted]}
    },
    join: %{
      representative: :join,
      fixture: """
      defmodule Posts do
        import Ecto.Query
        def q(query), do: join(query, :inner, [u], p in "posts", on: p.user_id == u.id)
      end
      """,
      dispatcher: [{~s|join(query, :inner, [u], p in "posts", on: p.user_id == u.id)|, "query"}],
      hosted: [{"p.user_id == u.id", "p.user_id != u.id"}],
      # The options list routes per-pair (as the `from` clause list does), so the `on:` condition's
      # `:hosted` sits nested under `{:keyword, …}` — still the routing branch's own answer, never
      # the `[]` catch-all.
      routing:
        {~s|join(query, :inner, [u], p in "posts", on: p.user_id == u.id)|,
         [:expression, :raw, :raw, :raw, {:keyword, [:hosted]}]}
    },
    # `:limit` is the one `:clause` shape with a host arm (the pin-only `:bound` bump —
    # `Host.host/2`'s `:clause` branch guards on `Surface.bound?/1`), so it exercises all three
    # loops with a single fixture where a plain clause macro (`group_by`, …) would leave the
    # host branch unproven.
    clause: %{
      representative: :limit,
      fixture: """
      defmodule Posts do
        import Ecto.Query
        def q(query), do: limit(query, 10)
      end
      """,
      # The bound *drop* stays a stage rewrite (`ClauseDrop` via the dispatcher's
      # `:clause`/`:join` branch); the *bump* below is the host's.
      dispatcher: [{"limit(query, 10)", "query"}],
      hosted: [{"10", "11"}, {"10", "9"}],
      routing: {"limit(query, 10)", [:expression, :hosted]}
    },
    dynamic: %{
      representative: :dynamic,
      fixture: """
      defmodule Posts do
        import Ecto.Query
        def d(v), do: dynamic([u], u.x > ^v)
      end
      """,
      # The whole-call in-place rewrite (`Dynamic` via the dispatcher's `:dynamic` branch).
      # Delivered as the whole rebuilt call; reported at the comparison (the walk's anchor).
      dispatcher: [{"u.x > ^v", "u.x >= ^v"}],
      hosted: :never_subscribed,
      routing: :registered_raw
    },
    raw: %{
      representative: :is_named_binding,
      fixture: """
      defmodule Posts do
        import Ecto.Query
        def q?(query), do: is_named_binding(query, :comments)
      end
      """,
      dispatcher: :deliberately_empty,
      hosted: :never_subscribed,
      routing: :registered_raw
    }
  }

  test "every Surface macro kind carries a probe here" do
    assert Enum.sort(Map.keys(@probes)) == Enum.sort(Surface.macro_kinds()),
           """
           `Surface.macro_kinds/0` and this probe table disagree — a macro kind was added,
           renamed, or removed. Each of the three kind dispatches ends in a silent catch-all,
           so extend the taxonomy by first adding a probe here that decides, for the new kind,
           what `Dispatcher.query_macro_mutations/3`, `Host.host/2`, and
           `Host.Routing.route_macro/4` must each do with it — a real branch, or an asserted
           structural exclusion (`:registered_raw` / `:never_subscribed`).
           """
  end

  for {kind, %{representative: representative}} <- @probes do
    test "#{kind}: the probe's representative (#{representative}) still classifies as #{kind}" do
      assert Surface.macro_kind(unquote(representative)) == unquote(kind)
    end
  end

  describe "Dispatcher.query_macro_mutations/3 takes a real branch per kind" do
    for {kind, probe} <- @probes do
      case probe.dispatcher do
        :deliberately_empty ->
          test "#{kind}: the whole call is offered but deliberately yields no mutation" do
            assert ecto_diffs(unquote(probe.fixture)) == []
          end

        pairs ->
          test "#{kind}: produces its branch's mutate/2 mutations" do
            diffs = ecto_diffs(unquote(probe.fixture))

            for pair <- unquote(Macro.escape(pairs)) do
              assert pair in diffs,
                     "missing #{inspect(pair)} in #{inspect(diffs)} — " <>
                       "did the dispatcher's #{unquote(kind)} branch go dead?"
            end
          end
      end
    end
  end

  describe "Host.host/2 takes a real branch per kind" do
    for {kind, probe} <- @probes do
      case probe.hosted do
        :never_subscribed ->
          test "#{kind}: structurally excluded — no #{kind}-kind macro subscribes to the host" do
            names = names_of(unquote(kind))

            assert names != [],
                   "no descriptor carries kind #{unquote(kind)} — dead taxonomy entry?"

            for name <- names do
              refute name in Surface.hosted_macro_names()
            end
          end

        pairs ->
          test "#{kind}: weaves its branch's hosted mutants" do
            assert unquote(probe.representative) in Surface.hosted_macro_names()
            diffs = ecto_diffs(unquote(probe.fixture))

            for pair <- unquote(Macro.escape(pairs)) do
              assert pair in diffs,
                     "missing #{inspect(pair)} in #{inspect(diffs)} — " <>
                       "did Host.host/2's #{unquote(kind)} branch go dead?"
            end
          end
      end
    end
  end

  describe "Host.Routing takes a real branch per kind" do
    for {kind, probe} <- @probes do
      case probe.routing do
        :registered_raw ->
          test "#{kind}: structurally excluded — every #{kind}-kind macro registers :raw" do
            names = names_of(unquote(kind))

            assert names != [],
                   "no descriptor carries kind #{unquote(kind)} — dead taxonomy entry?"

            registrations = Surface.macro_registrations()

            for name <- names do
              assert {name, :raw} in registrations,
                     "#{name} registers :routing but route_macro/4 has no #{unquote(kind)} branch"
            end
          end

        {snippet, expected} ->
          test "#{kind}: every #{kind}-kind macro registers :routing and the classifier routes it" do
            registrations = Surface.macro_registrations()

            for name <- names_of(unquote(kind)) do
              assert {name, :routing} in registrations
            end

            {name, _meta, args} = Sourceror.parse_string!(unquote(snippet))

            assert Host.Routing.treatments(name, args, :unpiped) ==
                     unquote(Macro.escape(expected)),
                   "treatments/3 fell through to a catch-all for: #{unquote(snippet)}"
          end
      end
    end
  end

  # Every macro name whose descriptor carries `kind` — so the structural-exclusion assertions
  # cover the whole kind, not just the probe's representative.
  defp names_of(kind) do
    for %{name: name} = descriptor <- Surface.descriptors(),
        Map.get(descriptor, :macro) == kind,
        do: name
  end
end
