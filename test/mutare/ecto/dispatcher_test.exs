defmodule Mutare.Ecto.DispatcherTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # `Mutare.Ecto.Dispatcher.mutations/2` classifies a node via `Mutare.Ecto.AST.QueryCall.parse/1`
  # first, falling back to the more general `Mutare.Calls.resolved_call/1` classification
  # (`call_mutations/3`'s `{@query_key, name, ...}` clause) only when that fails. A
  # **fully-qualified** call to an `Ecto.Query` function (`Ecto.Query.where(...)`, no `import
  # Ecto.Query` in scope) turns out to still resolve through the primary `QueryCall.parse/1` path
  # in the real scan pipeline (core's macro-identity stamping resolves by the same mechanism
  # regardless of import vs. full qualification) — so these tests, despite the shape, do not
  # actually exercise the `call_mutations/3` fallback clause. They still pin real, useful
  # behavior (a fully-qualified macro call is mutated exactly like an imported one), so they stay.
  # `Mutare.Transform.Resolve` stamps macro identity for the whole tree before any mutator runs, off
  # the same alias/import resolution `Calls.resolved_call/1` reads, so the two classifications can
  # never disagree for a macro this plugin registers — the fallback's `:condition`/`:clause`/
  # `:join`/`:dynamic` branches were confirmed unreachable and deleted (along with the identical
  # raw-node re-parse clauses in `Clause`/`Query`/`Dynamic`/`BindingReorder`); what remains of the
  # fallback (`{@query_key, _name, ...} -> QueryTerminal.mutations/2`) is the genuinely reachable
  # case: an `Ecto.Query` function this plugin doesn't register as a macro at all
  # (`Ecto.Query.exclude/2`, `subquery/1`, …).
  describe "a fully-qualified Ecto.Query macro call (no import in scope)" do
    test "a fully-qualified condition macro still hosts nothing but drops as a stage" do
      src = """
      defmodule M do
        def q(query), do: Ecto.Query.where(query, [u], u.x == u.y)
      end
      """

      diffs = ecto_diffs(src)
      assert {"u.x == u.y", "u.x != u.y"} in diffs
      assert {"Ecto.Query.where(query, [u], u.x == u.y)", "query"} in diffs
    end

    test "a fully-qualified clause macro (order_by) still gets its ordering mutations" do
      src = """
      defmodule M do
        def q(query), do: Ecto.Query.order_by(query, [u], asc: u.name)
      end
      """

      diffs = ecto_diffs(src)

      assert {"Ecto.Query.order_by(query, [u], asc: u.name)",
              "Ecto.Query.order_by(query, [u], desc: u.name)"} in diffs

      # `order_by` is not stage-droppable (an unordered query has an unspecified row order), so it
      # collapses to no `"query"` drop — the direction flip above is its reliable ordering mutant.
      refute {"Ecto.Query.order_by(query, [u], asc: u.name)", "query"} in diffs
    end

    test "a fully-qualified join macro still gets its on-condition and drop mutations" do
      src = """
      defmodule M do
        def q(query) do
          Ecto.Query.join(query, :inner, [u], p in Post, on: p.user_id == u.id)
        end
      end
      """

      diffs = ecto_diffs(src)
      assert {"p.user_id == u.id", "p.user_id != u.id"} in diffs

      assert {"Ecto.Query.join(query, :inner, [u], p in Post, on: p.user_id == u.id)", "query"} in diffs
    end

    test "a fully-qualified free-standing dynamic/2 still gets its in-fragment mutations" do
      src = """
      defmodule M do
        def d(v), do: Ecto.Query.dynamic([u], u.x > ^v)
      end
      """

      assert {"Ecto.Query.dynamic([u], u.x > ^v)", "Ecto.Query.dynamic([u], u.x >= ^v)"} in ecto_diffs(
               src
             )
    end

    test "a fully-qualified is_named_binding call resolves to no mutation (the :skip kind)" do
      # Mirrors `Mutare.Ecto.SurfaceTest`'s "entirely inert" case, but reached via this fallback
      # classification instead of the primary `QueryCall.parse` path.
      src = """
      defmodule M do
        def q?(query), do: Ecto.Query.is_named_binding(query, :comments)
      end
      """

      assert ecto_diffs(src) == []
    end
  end

  describe "the genuinely-reachable fallback — a non-macro Ecto.Query function" do
    test "a fully-qualified first/2 reaches QueryTerminal via the call_mutations fallback" do
      # Unlike the registered macros above (which route through the primary `QueryCall.parse/1`
      # path regardless of spelling), `first`/`last` are *plain* `Ecto.Query` functions the plugin
      # never registers as macros — so `QueryCall.parse/1` returns nil and dispatch falls through
      # to `call_mutations({@query_key, :first, …}) -> QueryTerminal`. This is the one fallback
      # branch that actually produces a mutation (the inert `is_named_binding` case above is its
      # empty twin), so it exercises the fallback classification this file exists to cover.
      src = """
      defmodule M do
        def q(query), do: Ecto.Query.first(query, :id)
      end
      """

      assert [{original, mutated}] = ecto_diffs(src)
      assert original =~ "Ecto.Query.first(query, :id)"
      assert mutated =~ "Ecto.Query.last(query, :id)"
    end
  end
end
