defmodule Mutare.Ecto.ShorthandTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  alias Mutare.Ecto.Host

  # The keyword-shorthand split: `where(q, col: val)`, the bindingless `from(S, where: [col:
  # val])`, and a join's `on: [col: val]` carry *data* values (not binding-referencing fragments),
  # so they are mutated by core's literal families — but delivered `^`-pinned (Ecto rejects a bare
  # selector `case` in a query value position), with the column-name keys left raw. This rides
  # core's per-keyword-pair routing + `:interpolated` extensions; here we assert the routing the
  # plugin emits and the end-to-end behaviour (value mutated, keys raw, metamutant compiles).

  @all [:all, {Mutare.Ecto, repo: MyApp.Repo}]

  # A `q |> macro(…)` snippet routes `:piped` — its visible args exclude the query, as core's do.
  defp routing(code) do
    case Sourceror.parse_string!(code) do
      {:|>, _meta, [_query, {name, _, args}]} -> Host.Routing.treatments(name, args, :piped)
      {name, _meta, args} -> Host.Routing.treatments(name, args, :unpiped)
    end
  end

  describe "treatments — the per-pair treatment the plugin emits" do
    test "a standalone shorthand routes each scalar value :interpolated, keys raw, query :expression" do
      # The directly-written query (`q`) is the threaded value — an ordinary expression.
      assert routing(~s|where(q, category: "Foo", count: 5)|) ==
               [:expression, {:keyword, [:interpolated, :interpolated]}]
    end

    test "the piped shorthand routes its sole keyword argument" do
      # Piped: the query is the `|>` left side (routed runtime separately), so the only visible
      # argument is the shorthand keyword list.
      assert routing(~s{q |> where(category: "Foo")}) == [{:keyword, [:interpolated]}]
    end

    test "a nil-valued pair is skipped (IS NULL, never = nil)" do
      assert routing(~s|where(q, deleted_at: nil)|) == [:expression, {:keyword, [:skip]}]
    end

    test "a compound (non-scalar) value is skipped (interpolation routing is scalar-only)" do
      assert routing(~s|where(q, ids: [1, 2])|) == [:expression, {:keyword, [:skip]}]
    end

    test "the binding form still hosts its condition (not shorthand), query :expression" do
      assert routing(~s|where(q, [u], u.x == u.y)|) == [:expression, :skip, :hosted]
    end

    test "a piped clause macro's visible first argument is never :expression" do
      # In the piped form the threaded query is the `|>` LHS (routed separately); the only visible
      # argument is data — a literal bound, an ordering. It must never route `:expression`: core
      # would mutate the bound/ordering, duplicating the plugin's own families and (for an
      # ordering) poisoning the query position. Pins that the pipe mode, not the argument's
      # shape, is what says so. A literal bound routes `:hosted` (the plugin's own pin-only
      # `:bound` bump — still not core's); an ordering stays raw.
      assert routing("q |> limit(10)") == [:hosted]
      assert routing("q |> offset(5)") == [:hosted]
      assert routing("q |> order_by(asc: :name)") == [:skip]
    end

    test "a bindingless from routes where/having values per-pair, other clauses raw" do
      assert [:skip, {:keyword, treatments}] =
               routing(~s|from("posts", where: [a: 1], select: [:id])|)

      # where value → nested {:keyword, [:interpolated]}; select → :skip.
      assert treatments == [{:keyword, [:interpolated]}, :skip]
    end

    test "a binding from can mix hosted expressions with shorthand values" do
      assert routing(~s|from(p in "posts", where: p.x == p.y, where: [active: true])|) ==
               [:skip, {:keyword, [:hosted, {:keyword, [:interpolated]}]}]
    end

    test "a standalone join's on: shorthand routes per-pair, like the from form's" do
      # A join's options list routes per-pair too, so its `on:` value takes the same shape rule as
      # a `from` clause's: an expression condition hosts, a shorthand routes its pairs.
      assert routing(~s|join(q, :inner, [u], p in Post, on: [views: 5])|) ==
               [:expression, :skip, :skip, :skip, {:keyword, [{:keyword, [:interpolated]}]}]

      assert routing(~s|join(q, :inner, [u], p in Post, on: p.user_id == u.id)|) ==
               [:expression, :skip, :skip, :skip, {:keyword, [:hosted]}]

      # Hostability is not re-decided by routing: an `assoc` join's `on:` is one Ecto folds under
      # an `and` (so `Mutare.Ecto.Host.JoinOn` refuses to weave a `^dynamic` there), but a
      # shorthand *value* pin is plain interpolation and stays legal — so the pairs still route.
      assert routing(~s|join(q, :inner, [u], p in assoc(u, :posts), on: [views: 5])|) ==
               [:expression, :skip, :skip, :skip, {:keyword, [{:keyword, [:interpolated]}]}]
    end
  end

  describe "end-to-end (core families mutate the value, ^-pinned)" do
    test "a standalone shorthand value is mutated, the key is not, and it compiles" do
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: where(query, category: "Foo")
      end
      """

      diffs = diffs(src, mutators: @all)

      # The value is mutated by a core literal family (its own name, not :ecto).
      assert Enum.any?(diffs, fn {_m, original, mutated} ->
               original == "\"Foo\"" and mutated == "\"\""
             end)

      # The column-name key is never mutated.
      refute Enum.any?(diffs, fn {_m, original, _mutated} -> original == "category" end)

      # Delivered ^-pinned (a bare selector case would poison the Ecto macro).
      assert metamutant(src, mutators: @all) =~ "^"
      assert_compiles(src, mutators: @all)
    end

    test "a bindingless from shorthand value is mutated; select field names are not" do
      src = """
      defmodule M do
        import Ecto.Query
        def q, do: from("posts", where: [category: "Foo"], select: [:id])
      end
      """

      diffs = diffs(src, mutators: @all)

      assert Enum.any?(diffs, fn {_m, original, _mutated} -> original == "\"Foo\"" end)
      # The select field name :id is not a value to mutate.
      refute Enum.any?(diffs, fn {_m, original, _mutated} -> original == ":id" end)

      assert_compiles(src, mutators: @all)
    end

    test "a binding from hosts an expression and core-mutates shorthand in the same clause list" do
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(p in "posts", where: p.score > 1, where: [active: true], select: p.id)
        end
      end
      """

      all_diffs = diffs(src, mutators: @all)

      assert {:ecto, "p.score > 1", "p.score >= 1"} in all_diffs

      assert Enum.any?(all_diffs, fn {_family, original, mutated} ->
               original == "true" and mutated == "false"
             end)

      assert_compiles(src, mutators: @all)
    end

    test "a standalone join's on: shorthand value is mutated; the column key is not" do
      # The `from` form (`join: …, on: [views: 5]`) always routed this per-pair; the standalone
      # `join/5` used to mark its whole options list `:hosted`, which left the value unreachable
      # for *every* family — the host's catalog reads SQL conditions, not keyword pairs.
      src = """
      defmodule M do
        import Ecto.Query
        def q(query), do: join(query, :inner, [u], p in MyApp.Post, on: [views: 5])
      end
      """

      diffs = diffs(src, mutators: @all)

      assert Enum.any?(diffs, fn {_m, original, mutated} ->
               original == "5" and mutated == "6"
             end)

      refute Enum.any?(diffs, fn {_m, original, _mutated} -> original == "views" end)

      # Delivered `^`-pinned inside the `on:` shorthand (a bare selector `case` there is poison).
      assert metamutant(src, mutators: @all) =~ "^case mutare_active"
      assert_compiles(src, mutators: @all)
    end

    test "an expression on: still hosts while a sibling option stays raw" do
      # The per-pair routing must not cost the hosted weave: the `on:` expression is still the
      # host's (an `:ecto` in-fragment swap), and `as:` is still untouched data.
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          join(query, :inner, [u], p in MyApp.Post, as: :p, on: p.user_id == u.id)
        end
      end
      """

      diffs = diffs(src, mutators: @all)

      assert {:ecto, "p.user_id == u.id", "p.user_id != u.id"} in diffs
      refute Enum.any?(diffs, fn {_m, original, _mutated} -> original == ":p" end)

      assert_compiles(src, mutators: @all)
    end
  end
end
