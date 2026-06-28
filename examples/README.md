# Examples

Two standalone Ecto apps to point `mutare_ecto` at, so you can watch it find test
gaps without needing an app of your own. Each is a real mix project with its own
`mix.exs`, schemas, migrations, and (deliberately partial) test suite.

| Example | What it is | What it shows |
| --- | --- | --- |
| [`hello`](hello/) | A "hello world" — one schema, one changeset, three queries | The smallest end-to-end run: a comparison, a sort, a limit, a validation drop |
| [`habit_tracker`](habit_tracker/) | A SQLite-backed habit-tracker CLI | The full catalog — joins, `group_by`/`having`, aggregates, `Ecto.Enum`, upserts, transactions, dynamically-built (`Enum.reduce`) queries — plus the SQL-equivalence annotations |

## Running

Unlike Mutare's own `examples/` (run with `mix mutare examples/<name>`), these
are **not** run from the repo root. `mutare_ecto` has to run **as a dependency of
the app under test** — that's what makes the app's `Repo` and schemas loadable, which the
plugin needs to expand `use Ecto.Schema` and resolve `Repo.*` calls. So each
example wires Mutare and this plugin in as dependencies, and you run from
*inside* it:

```
cd examples/hello          # or examples/habit_tracker
mix deps.get
mix test                   # green baseline — mutation testing needs a passing suite
mix mutare                 # mutate the Ecto surface and report the survivors
```

## The point isn't the score

Both suites have **partial coverage on purpose**, so every run surfaces real
survivors. Each example's `README.md` walks through its survivors and the
test-quality gap behind each one — a missing boundary fixture, weak test data
(only one entity's rows), an untested branch, an unasserted sort order. That's
what mutation testing is for, and an Ecto-aware mutator points it straight at
your filters, joins, and validations.
