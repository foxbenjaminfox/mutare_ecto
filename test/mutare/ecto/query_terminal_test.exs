defmodule Mutare.Ecto.QueryTerminalTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  # `Ecto.Query.first` ↔ `last` — a same-arity rename resolved through `Mutare.Transform.Calls`,
  # so qualified, aliased, and `import`ed forms all match.

  test "swaps first to last (qualified)" do
    src = """
    defmodule Q do
      def newest(query), do: Ecto.Query.first(query, :inserted_at)
    end
    """

    assert [{original, mutated}] = ecto_diffs(src)
    assert original =~ "first"
    assert mutated =~ "last(query, :inserted_at)"
  end

  test "swaps last to first under import Ecto.Query (bare call)" do
    src = """
    defmodule Q do
      import Ecto.Query
      def oldest(query), do: last(query)
    end
    """

    assert [{original, mutated}] = ecto_diffs(src)
    assert original =~ "last"
    assert mutated =~ "first"
    assert_compiles(src)
  end

  test "swaps in the pipe form" do
    src = """
    defmodule Q do
      import Ecto.Query
      def newest(query), do: query |> first()
    end
    """

    assert [{_original, mutated}] = ecto_diffs(src)
    assert mutated =~ "last"
    assert_compiles(src)
  end

  test "does not fire on an unrelated first/last call" do
    src = """
    defmodule Q do
      def newest(list), do: List.first(list)
    end
    """

    assert ecto_diffs(src) == []
  end
end
