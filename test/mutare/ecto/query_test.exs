defmodule Mutare.Ecto.QueryTest do
  use ExUnit.Case, async: true

  import Mutare.Ecto.TestSupport

  test "drops each where clause (binding form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from(p in "posts", where: p.active, where: not p.deleted, select: p.id)
    end
    """

    drops = Enum.filter(ecto_diffs(src), fn {_original, mutated} -> mutated =~ "from" end)

    # Two where clauses → two drop mutants; the surviving query keeps select and one where.
    assert length(drops) >= 2
    assert Enum.any?(drops, fn {_original, mutated} -> not (mutated =~ "active") end)
    assert Enum.any?(drops, fn {_original, mutated} -> not (mutated =~ "deleted") end)
  end

  test "drops a where clause (bindingless keyword form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from("posts", where: [active: true], select: [:id])
    end
    """

    assert Enum.any?(ecto_diffs(src), fn {_original, mutated} -> not (mutated =~ "active") end)
  end

  test "flips an order_by direction" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from(p in "posts", order_by: [asc: p.name])
    end
    """

    assert Enum.any?(ecto_diffs(src), fn {_original, mutated} -> mutated =~ "desc" end)
  end

  test "does not fire on a plain (non-from) call" do
    src = """
    defmodule M do
      def q(x), do: from_cache(x)
    end
    """

    assert ecto_diffs(src) == []
  end
end
