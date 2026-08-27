defmodule Mutare.Ecto.NormalizedASTTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.AST.{BindingList, FromCall, KeywordList, QueryCall}
  alias Mutare.Transform.Meta

  defp parse(code), do: Sourceror.parse_string!(code)

  describe "QueryCall" do
    test "normalizes a stamped Ecto.Query macro and rebuilds its written form" do
      {head, meta, args} = parse("Ecto.Query.limit(q, 10)")
      meta = Meta.stamp_macro_call(meta, {Mutare.Calls.module_key(Ecto.Query), :limit, :unpiped})
      call = QueryCall.parse({head, meta, args})

      assert %QueryCall{name: :limit, args: [_query, _bound]} = call

      assert call
             |> QueryCall.replace_arg(1, Mutare.AST.literal(20))
             |> Sourceror.to_string() == "Ecto.Query.limit(q, 20)"
    end

    test "rejects an unstamped or differently-owned call" do
      assert QueryCall.parse(parse("limit(q, 10)")) == nil

      {head, meta, args} = parse("Other.limit(q, 10)")
      meta = Meta.stamp_macro_call(meta, {[:Other], :limit, :unpiped})
      assert QueryCall.parse({head, meta, args}) == nil
    end
  end

  describe "BindingList" do
    test "validates entries and preserves the wrapper when transposing" do
      list = BindingList.parse(parse("[a, ..., b, post: p]"))

      assert %BindingList{} = list
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
      list = BindingList.parse(parse("[a, a]"))
      assert BindingList.transpositions(list) == []
    end

    test "accepts a bare list and rejects non-binding or empty lists" do
      assert %BindingList{} = BindingList.parse([{:a, [], nil}])
      assert BindingList.parse(parse("[active: true]")) == nil
      assert BindingList.parse(parse("[]")) == nil
      assert BindingList.parse(parse("a")) == nil
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
      meta = Meta.stamp_macro_call(meta, {Mutare.Calls.module_key(Ecto.Query), :from, :unpiped})
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
      meta = Meta.stamp_macro_call(meta, {Mutare.Calls.module_key(Ecto.Query), :limit, :unpiped})
      assert FromCall.parse({head, meta, args}) == nil
    end

    test "parse_args reads the shape without call identity" do
      [source, clauses] = args = parse("from(p in Post, where: p.x > 1)") |> elem(2)

      assert {^source, %KeywordList{entries: [%KeywordList.Entry{key: :where}]}} =
               FromCall.parse_args(args)

      assert {^source, %KeywordList{entries: []}} = FromCall.parse_args([source])
      assert FromCall.parse_args([source, parse("^clauses")]) == nil
      assert FromCall.parse_args([source, clauses, clauses]) == nil
    end
  end
end
