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

    sites = sites(src)
    drops = Enum.filter(sites, &(&1.mutator == :ecto and &1.mutated_code =~ "from"))

    # Two where clauses → two drop mutants; the surviving query keeps select and one where.
    assert length(drops) >= 2
    assert Enum.any?(drops, &(not (&1.mutated_code =~ "active")))
    assert Enum.any?(drops, &(not (&1.mutated_code =~ "deleted")))
  end

  test "drops a where clause (bindingless keyword form)" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from("posts", where: [active: true], select: [:id])
    end
    """

    sites = sites(src)
    assert Enum.any?(sites, &(&1.mutator == :ecto and not (&1.mutated_code =~ "active")))
  end

  test "flips an order_by direction" do
    src = """
    defmodule Posts do
      import Ecto.Query
      def q, do: from(p in "posts", order_by: [asc: p.name])
    end
    """

    sites = sites(src)
    assert Enum.any?(sites, &(&1.mutated_code =~ "desc"))
  end

  test "does not fire on a plain (non-from) call" do
    src = """
    defmodule M do
      def q(x), do: from_cache(x)
    end
    """

    assert sites(src) == []
  end
end
