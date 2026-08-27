defmodule Mutare.Ecto.ValueCatalogTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Surface, Tag, ValueCatalog}

  # Unit tests for the shared clause-value dispatch — the one capability → catalog mapping and
  # the one ordering-position rule that `Mutare.Ecto.Query` (whole-`from`), `Mutare.Ecto.Clause`
  # (standalone/pipe), and `Mutare.Ecto.Subquery` (a value-wrapped `select`) all rebuild through.

  describe "position/1" do
    test "a value is an ordering position iff its capabilities carry :ordering" do
      assert ValueCatalog.position([:ordering, :aggregate, :scalar]) == :ordering
      assert ValueCatalog.position([:aggregate, :scalar]) == :value
      assert ValueCatalog.position([]) == :value
    end

    test "the whole-from key and the standalone macro agree on every owned name" do
      # The two deliveries read different `Surface` capability lists (`from:` for a clause key,
      # `mutations:` for a macro); the rule must resolve them identically wherever both exist.
      for %{name: name} = descriptor <- Surface.descriptors(),
          Map.has_key?(descriptor, :from) and Map.has_key?(descriptor, :mutations) do
        assert ValueCatalog.position(Surface.from_capabilities(name)) ==
                 ValueCatalog.position(Surface.mutations(name)),
               "#{name} resolves to different positions by key and by macro"
      end

      assert ValueCatalog.position(Surface.mutations(:order_by)) == :ordering
      assert ValueCatalog.position(Surface.mutations(:prepend_order_by)) == :ordering
      assert ValueCatalog.position(Surface.from_capabilities(:select)) == :value
    end
  end

  describe "mutants/3" do
    test ":ordering flips the direction through the ordering catalog" do
      value = Sourceror.parse_string!("[asc: u.name]")

      assert [%Tag{family: :ordering, label: "asc"}] =
               ValueCatalog.mutants(:ordering, value, :ordering)
    end

    test ":aggregate swaps the aggregate regardless of position" do
      value = Sourceror.parse_string!("sum(u.amount)")

      for position <- [:value, :ordering] do
        assert [%Tag{family: :aggregate, label: "sum"}] =
                 ValueCatalog.mutants(:aggregate, value, position)
      end
    end

    test ":scalar threads the position to the coalesce drop's label" do
      value = Sourceror.parse_string!("coalesce(u.score, 0)")

      assert [%Tag{family: :coalesce, label: "coalesce"}] =
               ValueCatalog.mutants(:scalar, value, :value)

      assert [%Tag{family: :coalesce, label: "coalesce_in_ordering"}] =
               ValueCatalog.mutants(:scalar, value, :ordering)
    end
  end
end
