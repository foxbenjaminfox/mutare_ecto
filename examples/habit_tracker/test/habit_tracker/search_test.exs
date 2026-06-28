defmodule HabitTracker.SearchTest do
  use HabitTracker.DataCase

  setup do
    read = habit_fixture(name: "Read", cadence: :daily)
    run = habit_fixture(name: "Run", cadence: :weekly)

    check_in_fixture(read, ~D[2024-03-10], 3)
    check_in_fixture(read, ~D[2024-03-09], 1)
    check_in_fixture(read, ~D[2024-03-05], 5)
    check_in_fixture(run, ~D[2024-03-10], 2)

    :ok
  end

  defp dates(filters), do: filters |> Search.check_ins() |> Enum.map(& &1.date)

  test "no filters returns every check-in, newest first" do
    assert dates([]) == [~D[2024-03-10], ~D[2024-03-10], ~D[2024-03-09], ~D[2024-03-05]]
  end

  # Pins the dynamic `join` + `where h.name`: only Read's check-ins, in order.
  test "filters by habit (joining habits by name)" do
    assert dates(habit: "Read") == [~D[2024-03-10], ~D[2024-03-09], ~D[2024-03-05]]
  end

  # Pins the `>=` lower bound (a check-in *on* the `since` date is included) and
  # the `:desc` order. Note the `until` upper bound is the max date in the data, so
  # *dropping* it changes nothing — a survivor, since no fixture sits above it.
  test "filters by a date range" do
    assert dates(since: ~D[2024-03-09], until: ~D[2024-03-10]) ==
             [~D[2024-03-10], ~D[2024-03-10], ~D[2024-03-09]]
  end

  test "filters by a minimum count" do
    assert dates(min_count: 3) == [~D[2024-03-10], ~D[2024-03-05]]
  end

  # Both filters need the habits join, so this also pins the "join only once" guard
  # — joining twice would raise on the duplicate `:habit` binding.
  test "combines habit and cadence filters without joining twice" do
    assert dates(habit: "Read", cadence: :daily) ==
             [~D[2024-03-10], ~D[2024-03-09], ~D[2024-03-05]]

    assert dates(habit: "Read", cadence: :weekly) == []
  end
end
