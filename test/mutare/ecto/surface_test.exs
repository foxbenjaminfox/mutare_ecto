defmodule Mutare.Ecto.SurfaceTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Surface

  test "the descriptor table is the single macro-registration source" do
    registrations = Surface.macro_registrations()

    assert {:from, :routing} in registrations
    assert {:where, :routing} in registrations
    assert {:join, :routing} in registrations
    assert {:order_by, :routing} in registrations
    assert {:dynamic, :skip} in registrations
    assert {:is_named_binding, :skip} in registrations

    assert Enum.count(registrations, fn {name, _routing} -> name == :join end) == 1
  end

  test "dynamic registers :skip for core but keeps its own mutation surface" do
    # Core must never descend into the DSL arguments (hence the `:skip` registration above), and
    # the host never sees it — but the whole call is offered to `mutate/2`, where
    # `Mutare.Ecto.Dynamic` rewrites the condition and `Mutare.Ecto.BindingReorder` transposes the
    # written binding list.
    assert Surface.macro_kind(:dynamic) == :dynamic
    assert Surface.binding_list_macro?(:dynamic)
    refute :dynamic in Surface.hosted_macro_names()
    refute Surface.query_builder?(:dynamic)
    assert Surface.stage_drop_family(:dynamic) == nil
  end

  test "one descriptor separates routing, mutations, and stage/from removal" do
    assert Surface.descriptor(:order_by) == %{
             name: :order_by,
             macro: :clause,
             mutations: [:ordering, :aggregate],
             stage_drop: :clause_drop,
             from: [:ordering, :aggregate]
           }

    assert Surface.macro_kind(:order_by) == :clause
    assert Surface.mutations(:order_by) == [:ordering, :aggregate]
    assert Surface.stage_drop_family(:order_by) == :clause_drop
    assert Surface.from_clause?(:order_by, :ordering)
    assert Surface.from_drop_family(:order_by) == nil
  end

  test "condition and bound descriptors keep stage and whole-from families aligned" do
    for condition <- ~w(where or_where having or_having)a do
      assert Surface.macro_kind(condition) == :condition
      assert Surface.stage_drop_family(condition) == :filter_drop
      assert Surface.from_clause?(condition, :hosted)
      assert Surface.from_drop_family(condition) == :filter_drop
    end

    for bound <- [:limit, :offset] do
      assert Surface.mutations(bound) == [:bound]
      assert Surface.stage_drop_family(bound) == :bound
      assert Surface.from_clause?(bound, :bound)
      assert Surface.from_drop_family(bound) == :bound
    end
  end

  test "join descriptors distinguish binding accumulation from join-type mutation" do
    for join <- ~w(join inner_join left_join right_join full_join)a do
      assert Surface.from_clause?(join, :join_binding)
      assert Surface.from_clause?(join, :join_type)
    end

    for join <- ~w(cross_join inner_lateral_join left_lateral_join)a do
      assert Surface.from_clause?(join, :join_binding)
      refute Surface.from_clause?(join, :join_type)
    end

    assert Surface.macro_kind(:join) == :join
    assert Surface.macro_kind(:inner_join) == nil
  end

  test "unknown names are inert" do
    assert Surface.descriptor(:unknown) == nil
    assert Surface.macro_kind(:unknown) == nil
    assert Surface.mutations(:unknown) == []
    assert Surface.stage_drop_family(:unknown) == nil
    refute Surface.from_clause?(:unknown, :hosted)
    refute Surface.query_builder?(:unknown)
  end
end
