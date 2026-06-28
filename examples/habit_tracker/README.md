# habit_tracker — an Ecto-dense CLI

A command-line habit tracker that stores its data in a local SQLite file. It's
built to be a *rich* target for the Ecto mutator, so it deliberately uses a lot
of Ecto:

- **Schemas & associations** — `Habit` `has_many` `CheckIn`; `CheckIn`
  `belongs_to` `Habit`.
- **`Ecto.Enum`** for a habit's cadence (`:daily` / `:weekly`).
- **Migrations** (`create` + `alter table`) with indexes, a unique index, and a
  foreign key — run on boot.
- **Changesets** — `validate_required`, `validate_length`, `validate_inclusion`,
  `validate_number`, `unique_constraint`, `assoc_constraint`.
- **The query DSL** — `where` (with `in` membership and `and` / `or` / `not`
  connectives), `join` / `left_join`, `group_by`, `having`, `order_by` (including
  an explicit `:desc_nulls_last` NULLS placement), `limit`, `is_nil`, aggregates
  (`sum` / `avg` / `count` / `max`), `preload`.
- **`Repo.aggregate`**, an **upsert** (`on_conflict`), and an **`Ecto.Multi`**
  transaction.
- **Optimistic locking** — a `lock_version` column + `optimistic_lock/3`, so a
  concurrent (stale) update raises `Ecto.StaleEntryError` instead of clobbering.
- **Composable, dynamically-built queries** — `HabitTracker.Search` folds a set
  of optional filters into a query with `Enum.reduce`, piping each one through
  `where` / `join` / `limit`, and adds the `habits` join *once* on demand via
  `with_named_binding/3`.
- **Ellipsis bindings** — `Stats.active_since/1` filters on the most-recently
  joined table with `where([..., c], ...)`, skipping the bindings ahead of it.

## Run it as a tool

The CLI keeps its data in `./habit_tracker.db` (override with `HABIT_TRACKER_DB`):

```
cd examples/habit_tracker
mix deps.get
bin/habit add "Read" --target 1
bin/habit add "Exercise" --cadence weekly --target 3
bin/habit check "Read"
bin/habit check "Read" --date 2024-03-10 --count 2
bin/habit streak "Read"
bin/habit list
bin/habit stats
bin/habit history --habit Read --since 2024-03-01 --min-count 2
bin/habit rm "Exercise"
```

## Run the mutator

Mutare runs **as a dependency of the app under test** (so the Repo and schemas
are loadable), so run it from this directory:

```
mix test          # green baseline — mutation testing needs a passing suite
mix mutare        # mutate the Ecto surface and report the survivors
```

`.mutare.exs` enables just the Ecto plugin and excludes the CLI / boot glue, so
the run is all about the data layer. (Add `:all` to also mutate the plain
Elixir — the streak arithmetic, the changeset literals — for a fuller picture.)

## What you'll see

Abridged — a handful of the 32 survivors, and the trailing note on the
equivalence-sensitive ones is shortened (the real run spells it out further):

```
mutare: 93 mutants across 5 file(s)

lib/habit_tracker/habit.ex:35  [ecto, in-place]  SURVIVED
-    |> validate_length(:name, min: 2, max: 40)
+    |> Elixir.Function.identity()

lib/habit_tracker/stats.ex:22  [ecto, in-place]  SURVIVED  — kill may require an orphan row — a preserved-side row with no match (join kinds coincide when every row matches)
-      join: c in assoc(h, :check_ins),
+      left_join: c in assoc(h, :check_ins),

lib/habit_tracker/stats.ex:26  [ecto, in-place]  SURVIVED  — kill may require a row whose value sits exactly on the bound — strict and non-strict comparisons (< vs <=, > vs >=) select the same rows except one equal to the bound
-      having: sum(c.count) >= ^min_total,
+      having: sum(c.count) > ^min_total,

lib/habit_tracker/stats.ex:84  [ecto, in-place]  SURVIVED  — kill may require NULL rows in the ordered column — nulls_first and nulls_last only change where NULLs sort, ordering all other rows identically
-      order_by: [desc_nulls_last: max(c.date)],
+      order_by: [desc_nulls_first: max(c.date)],

lib/habit_tracker/tracker.ex:82  [ecto, in-place]  SURVIVED
-      from(c in CheckIn, where: c.habit_id == ^habit.id, select: c.date)
+      from(c in CheckIn, select: c.date)

lib/habit_tracker/search.ex:59  [ecto, in-place]  SURVIVED
-  defp apply_filter({:until, date}, query), do: where(query, [check_in: c], c.date <= ^date)
+  defp apply_filter({:until, date}, query), do: query

lib/habit_tracker/habit.ex:40  [ecto, in-place]  SURVIVED
-    |> optimistic_lock(:lock_version)
+    |> Elixir.Function.identity()

mutation score: 64.0%  (57 killed, 32 survived, 4 no-coverage, 93 total)
```

The 32 survivors cluster into a few honest lessons.

### 1. Validations no test exercises

Seven changeset rules can be dropped without a test noticing
(`validate_length`, `validate_inclusion`, `validate_number`, `assoc_constraint`,
the `check_ins` `unique_constraint`, …). The suite only ever submits *valid*
attributes, so the rules never fire. The fix is to assert the failure each rule
exists to produce — a one-character name, a zero target, a bad cadence.

For contrast, `validate_required(:name)` and `unique_constraint(:name)` on a
habit **are** tested (a nameless habit and a duplicate name), so dropping *those*
is killed. Same kind of rule — one verified, one not.

### 2. The fixtures only ever hold one habit's data

The most repeated survivor is the same shape three times — dropping
`where: c.habit_id == ^habit.id` in `total_count`, `current_streak`, and the
`delete_habit` transaction:

```
from(c in CheckIn, where: c.habit_id == ^habit.id)  →  from(c in CheckIn, [])
```

Every test sets up exactly one habit's check-ins, so a query that forgets to
filter by habit looks identical to one that remembers. With a *second* habit's
check-ins in the database, deleting that `where` would pull in rows that don't
belong — and the mutant would die. **Weak test data, not a missing test.**

### 3. Query shape that no assertion pins

`recent_check_ins/2` is checked only for its row *count*, so flipping its
`:desc` to `:asc` and dropping its `limit` both survive. And on the leaderboard,
the `where archived == false` and the `having` threshold can be dropped because
the fixtures contain no archived habit and none sitting on the boundary.

### 4. SQL-equivalence annotations — honest "maybe unkillable"

Two survivors carry a note instead of a plain `SURVIVED`, because they may be
unkillable for a *data* reason rather than a test gap — and the Ecto mutator
knows the difference:

- `join` → `left_join` reads **`kill may require an orphan row`**. The two joins
  differ only when a habit has *no* check-in; every habit in the leaderboard
  fixture has one, so the result is identical. Add a check-in-less habit and the
  left join would include it (with a `NULL` sum) — killing the mutant.
- `having: sum(...) >= ^min_total` → `>` reads **`kill may require a row whose
  value sits exactly on the bound`**. `>=` and `>` agree on every row except one
  sitting *exactly* on the threshold — which no fixture provides.

Each note names the *specific* data a kill needs — an orphan row here, a boundary
row there — because the reasons differ (join cardinality versus a missing
boundary value). That precision comes from the library reasoning in SQL's
semantics, not Elixir's — the whole point of a dedicated Ecto mutator.

### 5. A dynamically-built query, only partly driven

`HabitTracker.Search` assembles its query by folding filters in with
`Enum.reduce`, so each filter is its *own* `where` / `join` / `limit` stage that
the mutator can drop independently. Two parts go unverified:

- The **`until` upper bound** can be dropped (`where c.date <= ^date` → the query
  unchanged). The tests only ever pass an `until` equal to the newest check-in, so
  nothing sits above it and the bound never excludes a row. The `since` lower
  bound, by contrast, *is* pinned — a check-in sits exactly on it.
- The **`:limit` filter** is never passed in a test, so its `limit` stage is
  no-coverage: `Search.check_ins(limit: n)` is never exercised.

That every filter is a separately-droppable stage is the point of the composable
pipe form — and exactly the surface the Ecto mutator's pipe routing covers.

### 6. A guard whose failure mode no test triggers

`update_habit/2` runs the changeset through `optimistic_lock(:lock_version)`, so a
*stale* update — two processes load the same habit, both save — raises
`Ecto.StaleEntryError` instead of silently clobbering. The suite updates a habit
and checks the new value, but never sets up that conflict, so dropping the lock
changes nothing it observes. This is the `hook_drop` family, and the survivor
reads differently from the others: not "your filter is wrong" but *"the
concurrency guard the `lock_version` column exists for is untested."* The kill is
a test that loads the habit twice, saves one copy, and asserts the other raises.
(The `Repo.update` in `update_habit/2` survives for the same reason the insert
does — no test reads the row back to confirm the write landed.)

### 7. Where NULLs sort — and it's the same missing fixture as the orphan row

`by_recent_activity/0` ranks habits by their most recent check-in
(`order_by: [desc_nulls_last: max(c.date)]`), with the dormant ones — never
checked in, so a `NULL` `max(date)` out of the `left_join` — pinned to the bottom.
Its test asserts the ranking *and* each habit's last-active date, so the `:desc`
direction flip and both `max → min` aggregate swaps (in the `order_by` and the
`select`) are all killed. But two survivors remain, each carrying its **own**
note:

```
lib/habit_tracker/stats.ex:84  SURVIVED  — kill may require NULL rows in the ordered column — …
-      order_by: [desc_nulls_last: max(c.date)],
+      order_by: [desc_nulls_first: max(c.date)],

lib/habit_tracker/stats.ex:84  SURVIVED  — kill may require an orphan row — …
-      left_join: c in assoc(h, :check_ins),
+      inner_join: c in assoc(h, :check_ins),
```

This is the lesson the Ecto mutator is built to make: a nulls-qualified ordering
key has **two independent axes**, and they mutate separately. A bare `:desc`
asserts nothing about NULLs and gets only the direction flip; writing
`:desc_nulls_last` is the author saying *they care where NULLs land*, so it also
gets a placement flip (`:desc_nulls_last` → `:desc_nulls_first`) under its own
`ordering_nulls` family — equivalence-sensitive, because only a row with a `NULL`
in the ordered column can tell the two placements apart.

And here that placement survivor sits next to a `join_type` survivor with a
*different* note — **two distinct SQL phenomena, NULL ordering and join
cardinality, that happen to coincide on one missing fixture**: a single
never-checked-in habit. Add one (and assert it sorts last), and the `left_join`
keeps it with a `NULL` date that `desc_nulls_last` pins to the bottom — killing
both mutants at once. The notes aren't redundant; they just point at the same gap
from two directions.

## What's pinned down

Several queries are killed across the board because a test asserts the actual
rows, in order:

- `never_checked_in/0` — turning its `left_join` into an inner join, or flipping
  `is_nil(c.id)`, is caught (a habit with no check-ins must appear).
- `check_ins_since/1` — the `>=` boundary and the `:desc` order are both pinned
  (a check-in *on* the cutoff is asserted to be included).
- `total_count/1` — `sum` → `avg` is killed (two differing counts give different
  numbers).
- `list_habits/1` — the alphabetical order and the `archived == false` filter
  are both asserted.
- `Search.check_ins/1` — filtering by habit, by the `since` boundary, and by a
  minimum count are each asserted to exact, ordered results, so dropping those
  `where`s or flipping their comparisons is caught — even though the query is
  built up one stage at a time.
- `Stats.active_since/1` — the ellipsis-binding date filter (`where([..., c], ...)`)
  is pinned: a habit whose only check-in lands *on* the cutoff is asserted to be
  included, so `>=` → `>` is caught.
- `Tracker.by_cadence/2` — the membership-plus-connective filter
  (`h.cadence in ^cadences and (… or not h.archived)`) is pinned to exact results,
  so `in` → `not in` and `and` → `or` are both killed. Both reason under SQL's
  NULL semantics (the `and`/`or` swap is the genuine three-valued-logic case);
  here, on the non-null `cadence` / `archived` columns, they're cleanly killable —
  the contrast with the `NULL`-noted survivors above (the same kind of operator,
  but on a nullable column) is the lesson.

The throughline is the same one [`../hello`](../hello) shows in miniature:
asserting *counts* or *that it didn't crash* leaves the filter, the order, the
boundary, and the join cardinality unverified — and that's exactly what the
survivors point at.
