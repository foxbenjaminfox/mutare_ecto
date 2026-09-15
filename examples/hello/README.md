# hello — the smallest Ecto target

A "hello world" Ecto app: one `Repo`, one schema (`Hello.Greeting`), one
changeset, and three functions that read and write greetings. Just enough Ecto
to point the mutator at and watch it find a test gap.

## Run it

Mutare runs **as a dependency of the app under test** (so the `Repo` and schemas
are loadable), so run it from *inside this directory*:

```
cd examples/hello
mix deps.get
mix test          # green baseline — mutation testing needs a passing suite
mix mutare --sandbox ../hello_sandbox
                  # mutate the Ecto surface and report the survivors
```

The sandbox has to be a *sibling* directory: the plugin is a `../..` path dep,
and Mutare copies the project into the sandbox before compiling the metamutant,
so a sandbox anywhere else leaves that relative path dangling.

`.mutare.exs` enables only the Ecto plugin (`{Mutare.Ecto, repo: Hello.Repo}`),
so the run is small and focused; add `:all` to also mutate the plain Elixir in
`greet/1`.

## What you'll see

```
mutare: 8 mutants across 2 file(s)

lib/hello.ex:30  [ecto, in-place]  SURVIVED
-    |> order_by([g], desc: g.inserted_at)
+    |> order_by([g], asc: g.inserted_at)

lib/hello.ex:31  [ecto, in-place]  SURVIVED
-    |> limit(^limit)
+    |> Elixir.Function.identity()

lib/hello/greeting.ex:23  [ecto, in-place]  SURVIVED
-    |> validate_length(:name, min: 2)
+    |> Elixir.Function.identity()

mutation score: 62.5%  (5 killed, 3 survived, 8 total)
```

Three survivors, each a concrete, named test gap:

- **`recent_greetings/1` is barely tested.** Its only test checks that the call
  returns the right *number* of rows — never the order, never that the limit
  excludes any rows. So two mutations survive: flipping the sort `:desc` → `:asc` and
  dropping the `limit`. The fix is one assertion about *which* greetings come
  back, in *what* order.
- **`validate_length(:name, min: 2)` is never exercised.** The changeset test
  checks that a *missing* name is rejected, but no test submits a one-character
  name — so deleting the length rule changes nothing any test observes. (Its
  sibling, `validate_required`, *is* tested, so dropping *that* is killed.)

## What's pinned down — and why

`greetings_in/1` is the contrast. Its test seeds a French greeting alongside the
English ones and asserts the **exact, ordered** result — so every mutation of
that query is caught:

- `where: g.language == ^language` → `!=` is killed (it would return the French
  row and drop the English ones).
- dropping the `where` clause is killed (the French row leaks in).
- `order_by: [asc: g.name]` → `[desc: ...]` is killed (the names come back
  reversed).

And because that test reads its data back through the database, it also kills the
**persistence** mutant on `Repo.insert` (line 19): swap the real write for a
non-persisting `apply_action` and the rows are never there to read.

A test that asserts *counts* or *that it didn't crash* leaves the behaviour — the filter,
the order, the boundary — unverified. Asserting the actual rows is what kills the
mutants.

For a much larger target with the full catalog (joins, aggregates, `group_by` /
`having`, `Ecto.Enum`, upserts, transactions, associations), see
[`../habit_tracker`](../habit_tracker).
