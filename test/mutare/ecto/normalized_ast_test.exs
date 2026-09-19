defmodule Mutare.Ecto.NormalizedASTTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.AST.{BindingList, FromCall, KeywordList, QueryCall}
  alias Mutare.Transform.Meta

  defp parse(code), do: Sourceror.parse_string!(code)

  describe "QueryCall" do
    test "normalizes a stamped Ecto.Query macro and rebuilds its written form" do
      {head, meta, args} = parse("Ecto.Query.limit(q, 10)")
      meta = Meta.stamp_routed_call(meta, {Mutare.Calls.module_key(Ecto.Query), :limit, :unpiped})
      call = QueryCall.parse({head, meta, args})

      assert %QueryCall{name: :limit, args: [_query, _bound]} = call

      assert call
             |> QueryCall.replace_arg(1, Mutare.AST.literal(20))
             |> Sourceror.to_string() == "Ecto.Query.limit(q, 20)"
    end

    test "rejects an unstamped or differently-owned call" do
      assert QueryCall.parse(parse("limit(q, 10)")) == nil

      {head, meta, args} = parse("Other.limit(q, 10)")
      meta = Meta.stamp_routed_call(meta, {[:Other], :limit, :unpiped})
      assert QueryCall.parse({head, meta, args}) == nil
    end
  end

  describe "BindingList" do
    test "validates entries and preserves the wrapper when transposing" do
      assert {:ok, %BindingList{} = list} = BindingList.parse(parse("[a, ..., b, post: p]"))

      assert [{:positional, _a}, :ellipsis, {:positional, _b}, {:named, :post, _p}] = list.entries
      assert [swapped] = BindingList.transpositions(list)
      assert Sourceror.to_string(swapped) == "[b, ..., a, post: p]"
    end

    test "finds the first list and transposes only non-underscore positional bindings" do
      args = [parse("query"), parse("[_ignored, a, _, b]"), parse("[a.x, b.y]")]
      assert {1, %BindingList{} = list} = BindingList.find(args)

      assert Enum.map(BindingList.transpositions(list), &Sourceror.to_string/1) == [
               "[_ignored, b, _, a]"
             ]

      assert BindingList.find([parse("query"), parse("[a.x, b.y]")]) == nil
    end

    test "does not emit an unchanged transposition for repeated names" do
      {:ok, list} = BindingList.parse(parse("[a, a]"))
      assert BindingList.transpositions(list) == []
    end

    test "accepts a bare list and rejects a non-binding list or a non-list" do
      assert {:ok, %BindingList{}} = BindingList.parse([{:a, [], nil}])
      assert BindingList.parse(parse("[active: true]")) == :error
      assert BindingList.parse(parse("a")) == :error
    end

    # The declaration grammar is wider than the reorderable one: every form Ecto's
    # `escape_bind/1` reads parses, and only the plain positionals among them transpose.
    test "parses Ecto's whole entry grammar; only plain positionals are reorderable" do
      assert {:ok, list} = BindingList.parse(parse("[a, b, {c, 4}, {:post, p}, {^name, q}]"))

      assert [
               {:positional, _},
               {:positional, _},
               {:indexed, _, 4},
               {:named, :post, _},
               {:interpolated, _, _}
             ] = list.entries

      assert Enum.map(BindingList.transpositions(list), &Sourceror.to_string/1) == [
               "[b, a, {c, 4}, {:post, p}, {^name, q}]"
             ]

      # An indexed entry carries its own position, so transposing two is a no-op — none is offered.
      assert {:ok, indexed} = BindingList.parse(parse("[{a, 0}, {b, 1}]"))
      assert BindingList.transpositions(indexed) == []
    end

    test "the empty list is a declaration (of nothing), but find/1 skips it" do
      assert {:ok, %BindingList{entries: []}} = BindingList.parse(parse("[]"))

      args = [parse("query"), parse("[]"), parse("[a, b]")]
      assert {2, %BindingList{}} = BindingList.find(args)
      assert BindingList.find([parse("query"), parse("[]")]) == nil
    end

    test "one entry outside the grammar makes the whole list uninterpretable" do
      assert BindingList.parse(parse("[a, {p, index}]")) == :error
      assert BindingList.parse(parse("[a, {^name(), p}]")) == :error
    end
  end

  describe "KeywordList" do
    test "normalizes keys and rebuilds value, key, and deletion edits" do
      list = KeywordList.parse(parse("[where: u.active, limit: 10]"))

      assert Enum.map(list.entries, & &1.key) == [:where, :limit]

      assert list
             |> KeywordList.put_value(1, Mutare.AST.literal(20))
             |> KeywordList.to_ast()
             |> Sourceror.to_string() == "[where: u.active, limit: 20]"

      assert list
             |> KeywordList.put_key(1, :offset)
             |> KeywordList.to_ast()
             |> Sourceror.to_string() ==
               "[where: u.active, offset: 10]"

      assert list |> KeywordList.delete_at([0]) |> KeywordList.to_ast() |> Sourceror.to_string() ==
               "[limit: 10]"

      assert list
             |> KeywordList.delete_at([0, 1])
             |> KeywordList.to_ast()
             |> Sourceror.to_string() ==
               "[]"
    end

    test "last_of_key? asks whether a later entry repeats the key" do
      list = KeywordList.parse(parse("[limit: 5, where: u.active, limit: 10]"))

      refute KeywordList.last_of_key?(list, 0)
      assert KeywordList.last_of_key?(list, 1)
      assert KeywordList.last_of_key?(list, 2)
    end

    test "distinguishes a keyword list from mixed and non-list AST" do
      assert %KeywordList{entries: [_]} = KeywordList.nonempty(parse("[active: true]"))
      assert KeywordList.nonempty(parse("[]")) == nil
      assert KeywordList.parse(parse("[u.id, asc: u.name]")) == nil
      assert KeywordList.parse(parse("u.id")) == nil
    end
  end

  describe "FromCall" do
    # A stamped `from`, as the resolve pre-pass leaves it for `QueryCall.parse/1`.
    defp from(code) do
      {head, meta, args} = parse(code)
      meta = Meta.stamp_routed_call(meta, {Mutare.Calls.module_key(Ecto.Query), :from, :unpiped})
      FromCall.parse({head, meta, args})
    end

    test "reads a from apart and rebuilds each edit in the written form" do
      from = from("Q.from(p in Post, where: p.x > 1, limit: 10)")

      assert %FromCall{source: {:in, _, _}, clauses: %KeywordList{entries: [_, _]}} = from

      assert from |> FromCall.to_ast() |> Sourceror.to_string() ==
               "Q.from(p in Post, where: p.x > 1, limit: 10)"

      assert from
             |> FromCall.replace_clause(1, Mutare.AST.literal(20))
             |> FromCall.to_ast()
             |> Sourceror.to_string() == "Q.from(p in Post, where: p.x > 1, limit: 20)"

      assert from
             |> FromCall.rekey_clause(0, :having)
             |> FromCall.to_ast()
             |> Sourceror.to_string() ==
               "Q.from(p in Post, having: p.x > 1, limit: 10)"

      assert from |> FromCall.delete_clauses([1]) |> FromCall.to_ast() |> Sourceror.to_string() ==
               "Q.from(p in Post, where: p.x > 1)"

      assert from
             |> FromCall.replace_source(parse("c in Comment"))
             |> FromCall.to_ast()
             |> Sourceror.to_string() == "Q.from(c in Comment, where: p.x > 1, limit: 10)"
    end

    test "collapses an emptied clause list to the single-argument from" do
      # The collapse changes the call's arity (2 → 1), so core's rebuild requalifies a *bare*
      # imported `from` (an arity-restricted `import` could exclude `from/1`); a qualified or
      # aliased call keeps its written head.
      assert from("Q.from(p in Post, where: p.x > 1)")
             |> FromCall.delete_clauses([0])
             |> FromCall.to_ast()
             |> Sourceror.to_string() == "Q.from(p in Post)"

      assert from("from(p in Post, where: p.x > 1)")
             |> FromCall.delete_clauses([0])
             |> FromCall.to_ast()
             |> Sourceror.to_string() == "Elixir.Ecto.Query.from(p in Post)"
    end

    test "parses a clause-less from as an empty clause list, and rejects other shapes" do
      assert %FromCall{clauses: %KeywordList{entries: []}} = from = from("from(Post)")
      assert from |> FromCall.to_ast() |> Sourceror.to_string() == "from(Post)"

      assert from("from(p in Post, ^clauses)") == nil
      assert FromCall.parse(parse("from(p in Post, where: p.x > 1)")) == nil

      {head, meta, args} = parse("limit(q, 10)")
      meta = Meta.stamp_routed_call(meta, {Mutare.Calls.module_key(Ecto.Query), :limit, :unpiped})
      assert FromCall.parse({head, meta, args}) == nil
    end

    test "effective_clause? admits every clause but a last-wins key's overridden occurrence" do
      # `where` accumulates, so both occurrences reach the query; `limit` is last-wins
      # (`Surface.last_wins?/1`), so only its final occurrence does.
      from = from("from(p in Post, where: p.x > 1, limit: 5, where: p.y, limit: 10)")

      assert FromCall.effective_clause?(from, 0)
      refute FromCall.effective_clause?(from, 1)
      assert FromCall.effective_clause?(from, 2)
      assert FromCall.effective_clause?(from, 3)

      # A lone bound is its own last occurrence.
      assert FromCall.effective_clause?(from("from(p in Post, limit: 5)"), 0)
    end

    test "parse_args reads the shape without call identity" do
      [source, clauses] = args = parse("from(p in Post, where: p.x > 1)") |> elem(2)

      assert {^source, %KeywordList{entries: [%KeywordList.Entry{key: :where}]}} =
               FromCall.parse_args(args, :unpiped)

      assert {^source, %KeywordList{entries: []}} = FromCall.parse_args([source], :unpiped)
      assert FromCall.parse_args([source, parse("^clauses")], :unpiped) == nil
      assert FromCall.parse_args([source, clauses, clauses], :unpiped) == nil
    end

    # A stamped **piped** `from` (`Post |> from(…)`): the call node is the `from(…)` right side
    # alone, its source the hidden `|>` left — exactly what core's resolver leaves behind.
    defp piped_from(code) do
      {:|>, _pipe_meta, [source, {head, meta, args}]} = parse(code)

      meta =
        Meta.stamp_routed_call(
          meta,
          {Mutare.Calls.module_key(Ecto.Query), :from, {:piped, source}}
        )

      FromCall.parse({head, meta, args})
    end

    test "a piped from parses with its written source and rebuilds at its written arity" do
      from = piped_from("Post |> from(as: :post, where: as(:post).x > 1, limit: 10)")

      # The source is readable; reconstruction still takes only the visible arguments.
      assert %FromCall{
               source: {:__aliases__, _, [:Post]},
               clauses: %KeywordList{entries: [_, _, _]}
             } = from

      # Every edit rebuilds the `from(…)` half only — the source is never re-emitted, so the pipe
      # it sits on is untouched.
      assert from |> FromCall.to_ast() |> Sourceror.to_string() ==
               "from(as: :post, where: as(:post).x > 1, limit: 10)"

      assert from
             |> FromCall.replace_clause(2, Mutare.AST.literal(11))
             |> FromCall.to_ast()
             |> Sourceror.to_string() == "from(as: :post, where: as(:post).x > 1, limit: 11)"

      assert from |> FromCall.delete_clauses([1]) |> FromCall.to_ast() |> Sourceror.to_string() ==
               "from(as: :post, limit: 10)"

      # An emptied clause list collapses to the argless `from()` — the piped twin of `from(source)`.
      assert from
             |> FromCall.delete_clauses([0, 1, 2])
             |> FromCall.to_ast()
             |> Sourceror.to_string() == "Elixir.Ecto.Query.from()"

      # The argless spelling parses too, and a non-keyword clause argument is still rejected.
      assert %FromCall{source: {:__aliases__, _, [:Post]}, clauses: %KeywordList{entries: []}} =
               piped_from("Post |> from()")

      assert piped_from("Post |> from(^clauses)") == nil
    end

    test "a piped source cannot be silently replaced by a visible-call edit" do
      from = piped_from("([p, q] in query) |> from(where: p.id == q.id)")
      assert {:in, _, _} = from.source

      assert_raise FunctionClauseError, fn ->
        FromCall.replace_source(from, parse("[q, p] in query"))
      end
    end

    test "a literal nil source is not mistaken for a hidden argument" do
      assert from("from(nil)") |> FromCall.to_ast() |> Sourceror.to_string() == "from(nil)"
      assert %FromCall{source: {:__block__, _, [nil]}} = piped_from("nil |> from()")
    end

    test "parse_args reads the source from pipe-left identity" do
      [source, clauses] = parse("from(p in Post, where: p.x > 1)") |> elem(2)

      # Piped, the one visible argument is the clause list; the source comes from the stamp.
      assert {^source, %KeywordList{entries: [%KeywordList.Entry{key: :where}]}} =
               FromCall.parse_args([clauses], {:piped, source})

      assert {^source, %KeywordList{entries: []}} = FromCall.parse_args([], {:piped, source})

      # …so a two-argument piped `from` is malformed, as is a one-argument direct one that is not
      # a queryable-only call (`from(where: …)` has no source — Ecto rejects it too).
      assert FromCall.parse_args([source, clauses], {:piped, source}) == nil
      assert FromCall.parse_args([], :unpiped) == nil
    end
  end
end
