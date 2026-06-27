defmodule Mutare.Ecto.NormalizedASTTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.AST
  alias Mutare.Ecto.AST.{BindingList, KeywordList, QueryCall}
  alias Mutare.Transform.Meta

  defp parse(code), do: Sourceror.parse_string!(code)

  describe "QueryCall" do
    test "normalizes a stamped Ecto.Query macro and rebuilds its written form" do
      {head, meta, args} = parse("Ecto.Query.limit(q, 10)")
      meta = Meta.stamp_macro_call(meta, {AST.query_module_key(), :limit})
      call = QueryCall.parse({head, meta, args})

      assert %QueryCall{name: :limit, args: [_query, _bound]} = call

      assert call
             |> QueryCall.replace_arg(1, AST.int_literal(20))
             |> Sourceror.to_string() == "Ecto.Query.limit(q, 20)"
    end

    test "rejects an unstamped or differently-owned call" do
      assert QueryCall.parse(parse("limit(q, 10)")) == nil

      {head, meta, args} = parse("Other.limit(q, 10)")
      meta = Meta.stamp_macro_call(meta, {[:Other], :limit})
      assert QueryCall.parse({head, meta, args}) == nil
    end
  end

  describe "BindingList" do
    test "validates entries, exposes positionals, and preserves the wrapper when swapping" do
      list = BindingList.parse(parse("[a, ..., b, post: p]"))

      assert %BindingList{} = list
      assert BindingList.positionals(list) == [{0, :a}, {2, :b}]
      assert list |> BindingList.swap(0, 2) |> Sourceror.to_string() == "[b, ..., a, post: p]"
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
             |> KeywordList.replace_value(1, AST.int_literal(20))
             |> Sourceror.to_string() == "[where: u.active, limit: 20]"

      assert list |> KeywordList.replace_key(1, :offset) |> Sourceror.to_string() ==
               "[where: u.active, offset: 10]"

      assert list |> KeywordList.delete(0) |> Sourceror.to_string() == "[limit: 10]"
    end

    test "distinguishes a keyword list from mixed and non-list AST" do
      assert %KeywordList{entries: [_]} = KeywordList.nonempty(parse("[active: true]"))
      assert KeywordList.nonempty(parse("[]")) == nil
      assert KeywordList.parse(parse("[u.id, asc: u.name]")) == nil
      assert KeywordList.parse(parse("u.id")) == nil
    end
  end
end
