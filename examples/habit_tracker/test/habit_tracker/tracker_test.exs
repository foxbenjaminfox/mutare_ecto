defmodule HabitTracker.TrackerTest do
  use HabitTracker.DataCase

  describe "create_habit/1" do
    test "creates a valid habit with defaults" do
      assert {:ok, habit} = Tracker.create_habit(%{name: "Floss"})
      assert habit.name == "Floss"
      assert habit.cadence == :daily
      assert habit.target == 1
    end

    # Pins `validate_required(:name)` — dropping it is killed.
    test "requires a name" do
      assert {:error, changeset} = Tracker.create_habit(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    # Pins the `unique_constraint(:name)` — dropping it is killed.
    test "rejects a duplicate name" do
      habit_fixture(name: "Read")
      assert {:error, changeset} = Tracker.create_habit(%{name: "Read"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    # NB: nothing here ever submits a too-short name, a bad cadence, or a
    # non-positive target — so `validate_length`, `validate_inclusion`, and
    # `validate_number` are all droppable. Those survivors are the lesson.
  end

  describe "list_habits/1" do
    # Pins the alphabetical order *and* the archived filter: the result is the
    # exact, ordered list, so flipping the sort or the `archived == false`
    # comparison is caught.
    test "returns active habits, alphabetically" do
      habit_fixture(name: "Yoga")
      habit_fixture(name: "Books")
      {:ok, _} = Tracker.archive_habit(habit_fixture(name: "Old"))

      assert Enum.map(Tracker.list_habits(), & &1.name) == ["Books", "Yoga"]
    end
  end

  describe "by_cadence/2" do
    setup do
      daily = habit_fixture(name: "Floss", cadence: :daily)
      weekly = habit_fixture(name: "Gym", cadence: :weekly)
      {:ok, _} = Tracker.archive_habit(habit_fixture(name: "Old", cadence: :daily))
      %{daily: daily, weekly: weekly}
    end

    # Pins the membership *and* the connective: only the daily, non-archived habit
    # qualifies, so `in` → `not in`, `and` → `or`, and the archived guard are each
    # caught.
    test "returns active habits of the given cadence" do
      assert Enum.map(Tracker.by_cadence([:daily]), & &1.name) == ["Floss"]
    end

    # Pins the membership against a multi-element list.
    test "accepts several cadences" do
      assert Enum.map(Tracker.by_cadence([:daily, :weekly]), & &1.name) == ["Floss", "Gym"]
    end

    # Pins the `^include_archived or ...` branch — archived habits reappear.
    test "includes archived habits when asked" do
      assert Enum.map(Tracker.by_cadence([:daily], archived: true), & &1.name) == ["Floss", "Old"]
    end
  end

  describe "update_habit/2" do
    test "updates a habit's attributes" do
      habit = habit_fixture(name: "Read", target: 1)
      assert {:ok, updated} = Tracker.update_habit(habit, %{target: 3})
      assert updated.target == 3
    end

    # NB: nothing here loads the habit twice and asserts a *stale* update is
    # rejected, so dropping the `optimistic_lock` guard survives — the concurrency
    # protection the field exists for is never exercised.
  end

  describe "check_in/3" do
    # The upsert: a second check-in on the same date adds to that day's count
    # rather than failing on the unique index.
    test "a repeat check-in on the same day adds to the count" do
      habit = habit_fixture()
      {:ok, _} = Tracker.check_in(habit, ~D[2024-03-10], 1)
      {:ok, _} = Tracker.check_in(habit, ~D[2024-03-10], 2)

      assert Stats.total_count(habit) == 3
    end
  end

  describe "recent_check_ins/2" do
    # Loosely tested on purpose: we check the *count* but never the order or that
    # the limit bites — so the `:desc` sort, dropping the `order_by`, and dropping
    # the `limit` all survive.
    test "returns the habit's check-ins" do
      habit = habit_fixture()
      for d <- [~D[2024-03-10], ~D[2024-03-09], ~D[2024-03-08]], do: check_in_fixture(habit, d)

      assert length(Tracker.recent_check_ins(habit)) == 3
    end
  end

  describe "current_streak/2" do
    # Pins the consecutive-day loop: the count, the day-by-day step back, and the
    # gap that ends it are all asserted.
    test "counts consecutive days up to today" do
      habit = habit_fixture()
      for d <- [~D[2024-03-10], ~D[2024-03-09], ~D[2024-03-08]], do: check_in_fixture(habit, d)

      assert Tracker.current_streak(habit, ~D[2024-03-10]) == 3
    end

    test "stops at the first gap" do
      habit = habit_fixture()
      check_in_fixture(habit, ~D[2024-03-10])
      check_in_fixture(habit, ~D[2024-03-08])

      assert Tracker.current_streak(habit, ~D[2024-03-10]) == 1
    end
  end

  describe "delete_habit/1" do
    # The transaction removes the habit and its check-ins together.
    test "removes the habit and its check-ins" do
      habit = habit_fixture()
      check_in_fixture(habit, ~D[2024-03-10])

      assert {:ok, _} = Tracker.delete_habit(habit)
      assert Tracker.get_habit(habit.name) == nil
      assert Stats.total_count(habit) == 0
    end
  end
end
