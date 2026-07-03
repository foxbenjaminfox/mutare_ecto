defmodule HabitTracker.StatsTest do
  use HabitTracker.DataCase

  describe "leaderboard/1" do
    # Pins the ranking and the per-habit totals — so flipping the sort, or
    # swapping `sum` for `avg` in the SELECT, is caught. But the run never
    # includes an archived habit, nor one whose total sits *on* the default
    # `having` threshold of 1, so the `where archived == false` *drop*, and the
    # `having sum(...) >= 1` boundary, go unverified.
    test "ranks habits by total count, most active first" do
      reading = habit_fixture(name: "Read")
      running = habit_fixture(name: "Run")

      check_in_fixture(reading, ~D[2024-03-10], 3)
      check_in_fixture(reading, ~D[2024-03-09], 2)
      check_in_fixture(running, ~D[2024-03-10], 2)

      assert [
               %{name: "Read", total: 5, days: 2},
               %{name: "Run", total: 2, days: 1}
             ] = Stats.leaderboard()
    end
  end

  describe "busy_habits/1" do
    test "lists habits with more than min_days check-in days" do
      read = habit_fixture(name: "Read")
      run = habit_fixture(name: "Run")

      check_in_fixture(read, ~D[2024-03-10])
      check_in_fixture(read, ~D[2024-03-09])
      check_in_fixture(run, ~D[2024-03-10])

      assert Stats.busy_habits(1) == ["Read"]
    end
  end

  describe "never_checked_in/0" do
    # Pins the `left_join` + `is_nil`: a habit with no check-ins must appear, one
    # with a check-in must not. Turning the left join into an inner one, or
    # flipping `is_nil`, drops or inverts the result and is caught.
    test "lists only habits with no check-ins" do
      _fresh = habit_fixture(name: "New")
      active = habit_fixture(name: "Active")
      check_in_fixture(active, ~D[2024-03-10])

      assert Enum.map(Stats.never_checked_in(), & &1.name) == ["New"]
    end
  end

  describe "by_recent_activity/0" do
    # Pins the ranking *and* each habit's last-active date, so the `:desc`
    # direction flip and both `max → min` aggregate swaps (in the order_by and the
    # select) are caught. But every habit here has a check-in, so `max(c.date)` is
    # never NULL — nothing pins *where* a dormant habit would sort. So the
    # NULLS-placement flip (`:desc_nulls_last` → `:desc_nulls_first`) survives with
    # the equivalence note, exactly as the `left_join` → inner join does: both need
    # a never-checked-in habit in the data, and one would kill both at once.
    test "ranks habits by most recent activity, newest first" do
      read = habit_fixture(name: "Read")
      run = habit_fixture(name: "Run")

      # A crossover: Read is the more *recently* active (later max) but the earlier
      # *starter* (earlier min), so swapping `max` for `min` reorders them — which
      # is what kills the aggregate mutant in the order_by.
      check_in_fixture(read, ~D[2024-03-05])
      check_in_fixture(read, ~D[2024-03-11])
      check_in_fixture(run, ~D[2024-03-08])
      check_in_fixture(run, ~D[2024-03-10])

      assert Stats.by_recent_activity() == [
               %{name: "Read", last_active: ~D[2024-03-11]},
               %{name: "Run", last_active: ~D[2024-03-10]}
             ]
    end
  end

  describe "total_count/1" do
    # Pins the `Repo.aggregate(:sum, ...)`: with two differing counts, `:avg`
    # would give a different number, so the swap is killed.
    test "sums every logged count" do
      habit = habit_fixture()
      check_in_fixture(habit, ~D[2024-03-10], 2)
      check_in_fixture(habit, ~D[2024-03-09], 3)

      assert Stats.total_count(habit) == 5
    end

    test "is zero for a habit with no check-ins" do
      assert Stats.total_count(habit_fixture()) == 0
    end

    # NB: `average_count/1` has no test at all, so its `:avg` → `:sum` swap can't
    # be killed (it shows up as no-coverage, not as a survivor).
  end

  describe "progress_report/2" do
    # Pins several surfaces at once:
    #
    #   * the left join must keep a habit with no matching check-ins;
    #   * the date filters belong in the join `on:`, so out-of-window rows do not
    #     inflate the total but zero-progress habits still survive;
    #   * `coalesce(sum(...), 0)` must turn the dormant habit's NULL aggregate into
    #     zero;
    #   * the SQL arithmetic delta and its descending sort are asserted exactly;
    #   * archived habits are excluded.
    test "ranks active habits by window progress against target" do
      read = habit_fixture(name: "Read", target: 4)
      run = habit_fixture(name: "Run", target: 3)
      _idle = habit_fixture(name: "Idle", target: 2)
      archived = habit_fixture(name: "Old", target: 1)
      {:ok, _} = Tracker.archive_habit(archived)

      check_in_fixture(read, ~D[2024-03-10], 3)
      check_in_fixture(read, ~D[2024-03-11], 2)
      check_in_fixture(run, ~D[2024-03-10], 1)
      check_in_fixture(run, ~D[2024-03-01], 20)
      check_in_fixture(archived, ~D[2024-03-10], 50)

      assert Stats.progress_report(~D[2024-03-10], ~D[2024-03-11]) == [
               %{name: "Read", total: 5, target: 4, delta: 1},
               %{name: "Idle", total: 0, target: 2, delta: -2},
               %{name: "Run", total: 1, target: 3, delta: -2}
             ]
    end
  end

  describe "active_since/1" do
    # Pins the ellipsis-binding date filter: a habit whose only check-in sits *on*
    # the cutoff is included (so `>=` → `>` is caught), one whose check-ins are all
    # earlier is excluded (so dropping the `where` is caught), and one with no
    # check-ins at all never appears (the inner join).
    test "names habits checked in on or after the date" do
      read = habit_fixture(name: "Read")
      run = habit_fixture(name: "Run")
      old = habit_fixture(name: "Old")
      _idle = habit_fixture(name: "Idle")

      check_in_fixture(read, ~D[2024-03-10])
      check_in_fixture(read, ~D[2024-03-11])
      check_in_fixture(run, ~D[2024-03-05])
      check_in_fixture(old, ~D[2024-01-01])

      assert Stats.active_since(~D[2024-03-05]) == ["Read", "Run"]
    end
  end

  describe "check_ins_since/1" do
    # Pins the date filter *and* the order: a check-in exactly on the cutoff must
    # be included (so `>=` → `>` is caught) and the result is newest-first.
    test "returns check-ins on or after the cutoff, newest first" do
      habit = habit_fixture()
      check_in_fixture(habit, ~D[2024-03-10])
      check_in_fixture(habit, ~D[2024-03-09])
      check_in_fixture(habit, ~D[2024-03-08])

      dates = Stats.check_ins_since(~D[2024-03-09]) |> Enum.map(& &1.date)
      assert dates == [~D[2024-03-10], ~D[2024-03-09]]
    end
  end
end
