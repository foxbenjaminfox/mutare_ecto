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

  # Core's families plus **every** plugin family. The plugin's string/atom/boolean literal arms are
  # opt-in, so under the default families a predicate catalog wrongly let loose on `[active: true]`
  # finds nothing and the mistake stays invisible; with them on it flips the value and renames the
  # column. The ownership tests below run under this set so nothing hides.
  @every_family [:all, {Mutare.Ecto, repo: MyApp.Repo, families: :all}]

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
      assert routing(~s|where(q, deleted_at: nil)|) == [:expression, {:keyword, [:raw]}]
    end

    test "a compound (non-scalar) value is skipped (interpolation routing is scalar-only)" do
      assert routing(~s|where(q, ids: [1, 2])|) == [:expression, {:keyword, [:raw]}]
    end

    test "the binding form still hosts its condition (not shorthand), query :expression" do
      assert routing(~s|where(q, [u], u.x == u.y)|) == [:expression, :raw, :hosted]
    end

    test "a binding list before the shorthand does not make it a predicate" do
      # `where(q, [p], score: 5)` is Ecto's filter builder too (the pairs compare fields of the
      # first binding): what follows a binding list is *where a condition may sit*, not proof
      # that it is a predicate. The pairs route per-pair exactly as without the list; the list
      # itself stays raw.
      for macro <- ~w(where or_where having or_having) do
        assert routing(~s|#{macro}(q, [p], score: 5, title: "x")|) ==
                 [:expression, :raw, {:keyword, [:interpolated, :interpolated]}]

        assert routing(~s{q |> #{macro}([p], score: 5)}) == [:raw, {:keyword, [:interpolated]}]
      end

      # The pair-value exclusions are the same ones (`pair_treatment/1`).
      assert routing(~s|where(q, [p], a: ^v, b: 5)|) ==
               [:expression, :raw, {:keyword, [:raw, :interpolated]}]
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
      assert routing("q |> order_by(asc: :name)") == [:raw]
    end

    test "a bindingless from routes where/having values per-pair, other clauses raw" do
      assert [:raw, {:keyword, treatments}] =
               routing(~s|from("posts", where: [a: 1], select: [:id])|)

      # where value → nested {:keyword, [:interpolated]}; select → :skip.
      assert treatments == [{:keyword, [:interpolated]}, :raw]
    end

    test "a binding from can mix hosted expressions with shorthand values" do
      assert routing(~s|from(p in "posts", where: p.x == p.y, where: [active: true])|) ==
               [:raw, {:keyword, [:hosted, {:keyword, [:interpolated]}]}]
    end

    test "a standalone join's on: shorthand routes per-pair, like the from form's" do
      # A join's options list routes per-pair too, so its `on:` value takes the same shape rule as
      # a `from` clause's: an expression condition hosts, a shorthand routes its pairs.
      assert routing(~s|join(q, :inner, [u], p in Post, on: [views: 5])|) ==
               [:expression, :raw, :raw, :raw, {:keyword, [{:keyword, [:interpolated]}]}]

      assert routing(~s|join(q, :inner, [u], p in Post, on: p.user_id == u.id)|) ==
               [:expression, :raw, :raw, :raw, {:keyword, [:hosted]}]

      # Hostability is not re-decided by routing: an `assoc` join's `on:` is one Ecto folds under
      # an `and` (so `Mutare.Ecto.Host.JoinOn` refuses to weave a `^dynamic` there), but a
      # shorthand *value* pin is plain interpolation and stays legal — so the pairs still route.
      assert routing(~s|join(q, :inner, [u], p in assoc(u, :posts), on: [views: 5])|) ==
               [:expression, :raw, :raw, :raw, {:keyword, [{:keyword, [:interpolated]}]}]
    end
  end

  describe "Condition.shape/1 — the one predicate-versus-keyword-filter classification" do
    defp shape(code), do: code |> Sourceror.parse_string!() |> Host.Condition.shape()

    test "an expression is a predicate of kind :expression — a pin inside it included" do
      for code <- [
            "p.score > 5",
            "p.a == 1 and p.b == 2",
            "is_nil(p.x)",
            "p.score > ^min",
            "not ^cond",
            "true",
            "x"
          ] do
        assert shape(code) == {:predicate, :expression}, "expected `#{code}` to be an expression"
      end
    end

    test "a pin that is the whole condition is a predicate of kind :root_pin, whatever it carries" do
      # Ecto dispatches such a pin on its runtime value, so what the interior computes — a
      # dynamic, a boolean, a keyword list — never changes the kind.
      for code <- ["^cond", "^[score: 5]", "^true", "^(if on?, do: [active: true], else: [])"] do
        assert shape(code) == {:predicate, :root_pin}, "expected `#{code}` to be a root pin"
      end
    end

    test "locate/1 reports the kind of the predicate it located, in both argument forms" do
      for {code, kind} <- [
            {"where(q, [p], p.score > ^min)", :expression},
            {"where(q, as(:post).score > 5)", :expression},
            {"where(q, [p], ^cond)", :root_pin},
            {"where(q, ^cond)", :root_pin}
          ] do
        {:where, _meta, args} = Sourceror.parse_string!(code)

        assert %Host.Condition{kind: ^kind} = Host.Condition.locate(args),
               "expected `#{code}` to locate a #{kind}"
      end
    end

    test "a non-empty keyword list is a keyword filter, carrying its pairs" do
      assert {:keyword_filter, pairs} = shape(~s|[score: 5, title: "x"]|)
      assert Enum.map(pairs.entries, & &1.key) == [:score, :title]
    end

    test "every other list is the filter builder's too, with no pair to route" do
      # `[]` is Ecto's `true`; `[u]` and tuple-spelled pairs are lists the keyword reader does not
      # parse. None is ever a predicate — the predicate catalog walks list elements and tuple
      # sides as data, so handing it one of these is how a column gets renamed.
      for code <- ["[]", "[u]", "[{:score, 5}]", "[1, 2]"] do
        assert shape(code) == :pairless_list, "expected `#{code}` to be a pairless list"
      end
    end

    test "locate/1 declines a keyword filter in both argument forms" do
      for code <- ["where(q, score: 5)", "where(q, [p], score: 5)", "where(q, [p], [])"] do
        {:where, _meta, args} = Sourceror.parse_string!(code)
        assert Host.Condition.locate(args) == nil, "expected no located condition in `#{code}`"
      end
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

  describe "a keyword filter is never hosted as a predicate" do
    # `dynamic/2` is Ecto's general expression builder: it refuses a filter's pairs ("Tuples can
    # only be used in comparisons…") rather than translating them into field comparisons. So a
    # `dynamic(` around a shorthand is a metamutant that does not compile — and an `:ecto` diff
    # whose original is the whole list (other than the clause drop, a deletion) is the predicate
    # catalog at work where only core's per-pair families belong.

    # The diffs that touch the shorthand: the per-pair value mutants and anything recorded against
    # the list as a whole. `list` is the filter's written text.
    defp hosted_as_predicate(diffs, list) do
      for {:ecto, ^list, mutated} = diff <- diffs, mutated != "", do: diff
    end

    test "a shorthand after an explicit binding list is core's per pair, and compiles" do
      for call <- [
            "where(query, [p], score: 5)",
            "query |> where([p], score: 5)",
            "having(query, [p], score: 5)",
            "or_where(query, [p], score: 5)"
          ] do
        src = """
        defmodule M do
          import Ecto.Query
          def q(query), do: #{call}
        end
        """

        diffs = diffs(src, mutators: @every_family)

        # Core's integer family owns the value…
        assert {:integer, "5", "6"} in diffs, "no core mutant of the value in `#{call}`"

        # …and the plugin's predicate catalog owns nothing: no numeric bump of its own, no column
        # rename.
        assert hosted_as_predicate(diffs, "[score: 5]") == []

        mm = metamutant(src, mutators: @every_family)
        refute mm =~ "dynamic("
        assert mm =~ ~r/score:\s+\^case mutare_active do/
        assert_compiles(src, mutators: @every_family)
      end
    end

    test "numeric shorthand beside a hosted expression: each is delivered its own way" do
      # The numeric complement of the boolean mix above: the numeric literal arm is on by
      # default, so this is the shape where a predicate catalog let into the list would bump `5`
      # a second time and wrap the list in `dynamic/2`.
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(p in "posts", where: p.score > 1, where: [score: 5], select: p.id)
        end
      end
      """

      diffs = diffs(src, mutators: @all)

      assert {:ecto, "p.score > 1", "p.score >= 1"} in diffs
      assert {:integer, "5", "6"} in diffs
      assert hosted_as_predicate(diffs, "[score: 5]") == []

      # One `dynamic(` per branch of the *expression* condition's weave, none for the shorthand.
      refute metamutant(src, mutators: @all) =~ ~r/dynamic\(\[p\],\s*\[?score:/
      assert_compiles(src, mutators: @all)
    end

    test "the boolean mix, with every plugin family enabled" do
      src = """
      defmodule M do
        import Ecto.Query

        def q do
          from(p in "posts", where: p.score > 1, where: [active: true], select: p.id)
        end
      end
      """

      diffs = diffs(src, mutators: @every_family)

      assert {:ecto, "p.score > 1", "p.score >= 1"} in diffs
      assert {:boolean, "true", "false"} in diffs
      # Neither the plugin's boolean arm (`[active: false]`) nor its atom arm (`[mutare: true]`).
      assert hosted_as_predicate(diffs, "[active: true]") == []

      assert_compiles(src, mutators: @every_family)
    end
  end

  describe "composition: a hosted sibling never changes how a shorthand is read or delivered" do
    # Core offers the **whole call** to the host as soon as any one position routes `:hosted`,
    # and does not confine the returned targets to those positions. So whether the host is even
    # *asked* about a `from` depends on the shorthand's siblings — and the shorthand's fate must
    # not: the host reads the classifier's own decision (`Host.Condition.shape/1`).

    # Shorthand values: a numeric (the default-on literal arm), a boolean and a string (opt-in
    # arms), several pairs, and a pinned value — whose interior is nobody's (`pair_treatment/1`
    # routes it raw), so the host must not sub-contract it to core either.
    @shorthands [
      ~s|[score: 5]|,
      ~s|[active: true]|,
      ~s|[title: "x"]|,
      ~s|[score: 5, active: true]|,
      ~s|[score: ^(min + 1)]|,
      ~s|[score: ^(min + 1), active: true]|
    ]

    # Each sibling routes at least one position `:hosted`, which is what summons the host: a
    # pin-only bound, a hosted expression condition (before and after the shorthand), a hosted
    # join `on:`.
    @hosted_siblings [
      {"", ", limit: 10"},
      {"", ", offset: 3"},
      {"where: p.views > 7, ", ""},
      {"", ", where: p.views > 7"},
      {~s|join: c in "comments", on: c.post_id == p.id, |, ""},
      {"", ~s|, where: p.views > 7, limit: 10|}
    ]

    defp shorthand_from(key, shorthand, {before, after_}) do
      """
      defmodule M do
        import Ecto.Query
        def q(min), do: from(p in "posts", #{before}#{key}: #{shorthand}#{after_})
      end
      """
    end

    # How the shorthand is *interpreted*: every diff recorded inside it (a pair value's mutants)
    # or against it whole (its clause drop — and, were it hosted, the predicate catalog's).
    defp shorthand_diffs(src, shorthand) do
      for {_mutator, original, _mutated} = diff <- diffs(src, mutators: @every_family),
          String.contains?(shorthand, original),
          do: diff
    end

    # How it is *delivered*: every woven rendering of the shorthand's clause in the metamutant —
    # each `key:` value, in any `from`, that carries a selector and names the shorthand's first
    # column — with the mutant ids, the one thing a sibling legitimately shifts, blanked out. Read
    # off the metamutant's AST, so layout never matters. A per-pair delivery is
    # `[score: ^case … end]`; the predicate host's would be `^case … dynamic([p], score: 5) … end`;
    # a shorthand nobody mutates (a lone pinned value) has no woven rendering at all.
    defp shorthand_delivery(src, key, shorthand) do
      [{column, _value} | _] = Code.string_to_quoted!(shorthand)

      src
      |> metamutant(mutators: @every_family)
      |> Code.string_to_quoted!()
      |> Macro.prewalker()
      |> Enum.flat_map(fn
        {:from, _meta, [_ | _] = args} -> clause_values(List.last(args), key)
        _node -> []
      end)
      |> Enum.map(&(&1 |> blank_mutant_ids() |> Macro.to_string()))
      # `column:` with its colon — a bare `active` would also match `mutare_active`.
      |> Enum.filter(&(&1 =~ "mutare_active" and &1 =~ "#{column}:"))
      |> Enum.uniq()
      |> Enum.sort()
    end

    defp clause_values(clauses, key) when is_list(clauses),
      do: for({^key, value} <- clauses, do: value)

    defp clause_values(_not_a_clause_list, _key), do: []

    defp blank_mutant_ids(ast) do
      Macro.prewalk(ast, fn
        {:->, meta, [[id], body]} when is_integer(id) -> {:->, meta, [[:id], body]}
        {{:., _, [:mutare_cov, :hit]} = hit, meta, [_ids]} -> {hit, meta, [[:ids]]}
        node -> node
      end)
    end

    test "where: a shorthand reads and delivers the same with or without a hosted sibling" do
      for shorthand <- @shorthands do
        alone = shorthand_from("where", shorthand, {"", ""})
        expected_diffs = Enum.sort(shorthand_diffs(alone, shorthand))
        expected_delivery = shorthand_delivery(alone, :where, shorthand)

        for sibling <- @hosted_siblings do
          src = shorthand_from("where", shorthand, sibling)
          label = "`where: #{shorthand}` beside #{inspect(sibling)}"

          assert Enum.sort(shorthand_diffs(src, shorthand)) == expected_diffs,
                 "#{label} is interpreted differently"

          assert shorthand_delivery(src, :where, shorthand) == expected_delivery,
                 "#{label} is delivered differently"

          assert_compiles(src, mutators: @every_family)
        end
      end
    end

    test "a join's on: shorthand likewise — adding `limit: 10` changes nothing about it" do
      for shorthand <- [~s|[score: 5]|, ~s|[score: 5, active: true]|, ~s|[score: ^(min + 1)]|] do
        join = ~s|join: c in "comments", |
        alone = shorthand_from("on", shorthand, {join, ""})
        beside = shorthand_from("on", shorthand, {join, ", limit: 10"})

        assert Enum.sort(shorthand_diffs(beside, shorthand)) ==
                 Enum.sort(shorthand_diffs(alone, shorthand))

        assert shorthand_delivery(beside, :on, shorthand) ==
                 shorthand_delivery(alone, :on, shorthand)

        assert_compiles(beside, mutators: @every_family)
      end
    end

    test "the named regression: `limit: 10` beside `where: [score: 5]`" do
      alone = shorthand_from("where", "[score: 5]", {"", ""})
      beside = shorthand_from("where", "[score: 5]", {"", ", limit: 10"})

      # Spelled out, not just compared: core's three integer mutants and the plugin's clause
      # drop — nothing else, in either.
      expected =
        Enum.sort([
          {:integer, "5", "6"},
          {:integer, "5", "4"},
          {:integer, "5", "0"},
          {:ecto, "[score: 5]", ""}
        ])

      assert Enum.sort(shorthand_diffs(alone, "[score: 5]")) == expected
      assert Enum.sort(shorthand_diffs(beside, "[score: 5]")) == expected

      # Delivered per pair, identically: one woven rendering, the pin *inside* the list.
      assert [delivery] = shorthand_delivery(alone, :where, "[score: 5]")
      assert delivery =~ ~r/\A\[\s*score:\s+\^case mutare_active do/
      assert shorthand_delivery(beside, :where, "[score: 5]") == [delivery]

      # The sibling really is hosted (so the host really was offered the call)…
      assert {:ecto, "10", "11"} in diffs(beside, mutators: @every_family)
      # …and the only woven `dynamic` would have been the shorthand's.
      refute metamutant(beside, mutators: @every_family) =~ "dynamic("
      assert_compiles(beside, mutators: @every_family)
    end
  end

  describe "ownership is exclusive: no position is both routed per pair and hosted" do
    # Were one position owned twice, both owners would record their mutants but only one could
    # deliver: the host splices its `^case … dynamic(…)` over the whole clause value, overwriting
    # the pins core had placed inside the list. Core's per-pair mutants would then keep their
    # Sites and lose their selector branches — mutants no run can activate, reported as
    # survivors. So exclusivity is observable end to end: **every recorded mutant id has a branch
    # in the metamutant**, and the shorthand's Sites are core's alone.

    @owned_once [
      # {source body, the shorthand's written text}
      {~s|from(p in "posts", where: [score: 5], limit: 10)|, "[score: 5]"},
      {~s|from(p in "posts", where: [active: true, title: "x"], offset: 3)|,
       ~s|[active: true, title: "x"]|},
      {~s|from(p in "posts", where: p.views > 7, where: [score: 5])|, "[score: 5]"},
      {~s|from(p in "posts", group_by: p.id, having: [score: 5], where: p.views > 7)|,
       "[score: 5]"},
      {~s|from(p in "posts", join: c in "comments", on: [score: 5], limit: 10)|, "[score: 5]"},
      {~s|"posts" \|> from(as: :post, where: [score: 5], limit: 10)|, "[score: 5]"},
      {~s|where(query, [p], score: 5)|, "[score: 5]"},
      {~s|query \|> where([p], score: 5) \|> limit(10)|, "[score: 5]"},
      {~s|join(query, :inner, [p], c in "comments", on: [score: 5])|, "[score: 5]"},
      # An unnamed join's `on:` is hosted too (it still holds its binding slot), so the
      # shorthand check must reach it in both forms.
      {~s|join(query, :inner, [p], "comments", on: [score: 5])|, "[score: 5]"},
      {~s|join(query, :inner, [p], "comments", on: [score: 5]) \|> where([p, c], p.views > 7)|,
       "[score: 5]"},
      {~s|from(p in "posts", join: "comments", on: [score: 5], limit: 10)|, "[score: 5]"}
    ]

    defp owned_once_source(body) do
      """
      defmodule M do
        import Ecto.Query
        def q(query), do: #{body}
      end
      """
    end

    # The mutant ids the metamutant can actually select: the integer heads of its selector cases.
    defp reachable_ids(src) do
      src
      |> metamutant(mutators: @every_family)
      |> Code.string_to_quoted!()
      |> Macro.prewalker()
      |> Enum.flat_map(fn
        {:->, _meta, [[id], _body]} when is_integer(id) -> [id]
        _node -> []
      end)
      |> MapSet.new()
    end

    test "every recorded mutant is reachable, and a shorthand's value mutants are core's alone" do
      for {body, shorthand} <- @owned_once do
        src = owned_once_source(body)
        sites = sites(src, mutators: @every_family)

        recorded = MapSet.new(sites, & &1.id)
        orphaned = MapSet.difference(recorded, reachable_ids(src))

        assert MapSet.size(orphaned) == 0,
               "`#{body}` records mutants with no selector branch: " <>
                 inspect(
                   for site <- sites, site.id in orphaned, do: {site.mutator, site.mutated_code}
                 )

        # Per-pair ownership is real (core mutated a pair value)…
        assert Enum.any?(
                 sites,
                 &(&1.mutator != :ecto and String.contains?(shorthand, &1.original_code))
               ),
               "no core mutant inside `#{shorthand}` in `#{body}`"

        # …and sole: the plugin records nothing against the list but its clause/stage drop.
        diffs = for site <- sites, do: {site.mutator, site.original_code, site.mutated_code}
        assert hosted_as_predicate(diffs, shorthand) == [], "`#{body}` hosts its shorthand"
      end
    end

    test "the corpus is not vacuous: the hosted siblings are still hosted" do
      hosted? = fn body, diff ->
        diff in diffs(owned_once_source(body), mutators: @every_family)
      end

      assert hosted?.(~s|from(p in "posts", where: [score: 5], limit: 10)|, {:ecto, "10", "11"})

      assert hosted?.(
               ~s|from(p in "posts", where: p.views > 7, where: [score: 5])|,
               {:ecto, "p.views > 7", "p.views >= 7"}
             )

      assert hosted?.(
               ~s|from(p in "posts", join: "comments", on: [score: 5], limit: 10)|,
               {:ecto, "10", "11"}
             )

      assert hosted?.(
               ~s|join(query, :inner, [p], "comments", on: [score: 5]) \|> where([p, c], p.views > 7)|,
               {:ecto, "p.views > 7", "p.views >= 7"}
             )
    end
  end

  describe "a subquery's interior shorthand (delivered in place, inside a hosted condition)" do
    # The whole outer condition is hosted, so core never reaches the inner `from`'s pairs; and an
    # interior mutant is the inner `from` rebuilt, so the filter stays in a filter position — no
    # `dynamic/2` to refuse it. Its pair *values* are therefore the plugin's SQL data, like the
    # right side of the `c.score == 5` they abbreviate. Its *keys* name columns.

    test "pair values are mutated; a column key is never renamed" do
      src = """
      defmodule M do
        import Ecto.Query

        def q(query) do
          where(query, [p], exists(from(c in "comments", where: [score: 5, kind: :spam])))
        end
      end
      """

      mutateds =
        for {:ecto, _original, mutated} <- diffs(src, mutators: @every_family), do: mutated

      assert Enum.any?(mutateds, &(&1 =~ "where: [score: 6, kind: :spam]"))
      # The atom arm (opt-in, on here) still reaches the atom *value*…
      assert Enum.any?(mutateds, &(&1 =~ "where: [score: 5, kind: :mutare]"))
      # …but no key: `[mutare: 5, …]` / `[:mutare => 5, …]` is an unknown-column query.
      refute Enum.any?(mutateds, &(&1 =~ ~r/mutare:|:mutare =>/))

      assert_compiles(src, mutators: @every_family)
    end

    test "a pinned pair value is still an island of the interior" do
      src = """
      defmodule M do
        import Ecto.Query

        def q(query, min) do
          where(query, [p], exists(from(c in "comments", where: [score: ^(min + 1)])))
        end
      end
      """

      mutateds = for {_m, _original, mutated} <- diffs(src, mutators: @every_family), do: mutated

      assert Enum.any?(mutateds, &(&1 =~ "where: [score: ^(min + 2)]"))
      assert_compiles(src, mutators: @every_family)
    end
  end
end
