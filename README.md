# mutare_ecto

A mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), built as a custom
[Mutare](https://github.com/foxbenjaminfox/mutare) mutator.

Mutation testing checks how good your tests actually are: it makes small, deliberate changes to
your code — a `>` becomes a `>=`, a `where` clause is dropped, a `validate_required` is removed —
and reruns your suite. If the tests still pass, that mutation **survived**, and you've found a gap
your assertions don't cover.

`mutare_ecto` aims that lens at the Ecto code you write — `Repo` calls, changeset pipelines, and
the `from`/query DSL — so a survivor tells you something concrete: *"no test would notice if this
filter, this sort order, or this validation quietly changed."*

## Why a dedicated Ecto mutator

An Ecto `where` clause looks like Elixir, but it isn't — it's a fragment of SQL, and SQL runs
under **three-valued logic** (`NULL` is neither true nor false). A general-purpose mutator that
treats `a < b or a > b` as ordinary Elixir will "helpfully" conclude it's equivalent to `a != b`
and skip the mutation. In SQL that's wrong: when `a` or `b` is `NULL`, the two differ — and that's
exactly the untested edge you'd want flagged.

So `mutare_ecto` ships its **own** SQL-semantics mutation catalog and never borrows Mutare's
Elixir-semantics mutators inside a query. Every mutation it emits is one a real SQL engine will
run, and its equivalence reasoning is SQL's, not Elixir's.

## Installation

Add both Mutare and this plugin to the app you want to test, in `:dev`/`:test`:

```elixir
# mix.exs
defp deps do
  [
    {:mutare, "~> ..."},
    {:mutare_ecto, "~> ..."}
  ]
end
```

It must run **as a dependency of the app under test** (not against an external source path), so
your `Repo` and schemas are loadable in the Mutare process — that's what lets `use Ecto.Schema`
expand and the query macros resolve. External-source operation is unsupported: there is currently
no startup check for it, and unresolved target-app modules can make routing incomplete or invalid.

## Usage

Enable it in `.mutare.exs`, naming your Repo when Repo-call mutations are needed:

```elixir
# .mutare.exs
[
  mutators: [
    :all,                            # Mutare's built-ins for ordinary Elixir
    {Mutare.Ecto, repo: MyApp.Repo}  # the Ecto surface
  ]
]
```

Then run Mutare as usual. Listing the entry both registers the plugin's query-DSL routing and
enables its mutations; `repo:` is optional for query and changeset mutations, and is what lets it
recognise `Repo.*` calls regardless of how they're aliased or imported.

## What it mutates

Every mutation is tagged with a **family**, so you can enable or report on them individually
(see Configuration). They cover three surfaces:

**Inside `where` / `having` conditions** — delivered through Ecto's `^`/`dynamic` injection so
the query still compiles once and the active mutant is chosen at build time:

| Family | Example | Question a survivor raises |
|---|---|---|
| `comparison` | `u.age > 18` → `>= 18` | Is the boundary tested? |
| `null_predicate` | `is_nil(u.x)` → `not is_nil(u.x)` | Is the `NULL` case tested? |
| `connective` | `a and b` → `a or b` | Does any row distinguish the two? |
| `membership` | `x in ^list` → `x not in ^list`; `like` → `ilike` | Polarity / case-sensitivity |
| `integer_literal` | `u.age > 18` → `19` / `17` / `0` | Off-by-one in an integer literal |
| `float_literal` | `u.score > 2.5` → `3.5` / `1.5` / `0.0` | Off-by-one in a float literal |
| `string_literal` † | `u.name == "ok"` → `""` / `"mutare"` | Is the string value tested? |
| `atom_literal` † | `u.status == :active` → `:mutare` | Is the atom value tested? |
| `boolean_literal` † | `… and true` → `… and false` | Is the boolean operand tested? |
| `binding_reorder` | `[a, b]` → `[b, a]` | Does their declared order matter? |
| `filter_drop` | drop a whole `where`/`having` clause | Is this filter tested at all? |

† **Off by default** (opt-in). A string, atom, or boolean literal mutant is the most likely to be a
noisy survivor — a string/atom because its value space is large (an in-fragment string the
broadest), a boolean because a direct boolean literal in a condition is rarely idiomatic. Enable
them with `families: :all` or by naming them in an explicit list (see Configuration). The numeric
arms (`integer_literal`/`float_literal`) are on by default. Whatever the selection, a literal at a
**structural position** of a known Ecto DSL form — the `fragment` template, the interval unit of
`datetime_add`/`date_add`/`from_now`/`ago`, the cast type of `type/2` — is never mutated (it shapes
the SQL, so a mutant would just be a broken query, not a test signal).

**Query shape** — ordering, pagination, joins, aggregates, and the query terminals:

| Family | Example |
|---|---|
| `ordering` | `order_by: [asc: u.name]` → `[desc: u.name]` |
| `ordering_nulls` | `:asc_nulls_first` → `:asc_nulls_last` |
| `bound` | `limit: 10` → `9` / `11`, or drop the `limit`/`offset` |
| `join_type` | `join`/`inner_join` ↔ `left_join` (changes result cardinality) |
| `aggregate` | `sum(u.x)` ↔ `avg(u.x)`, `min` ↔ `max` (in `select` or `Repo.aggregate`) |
| `query_terminal` | `Ecto.Query.first` ↔ `last` |

**Repo writes and changesets** — plain calls, no query DSL involved:

| Family | Example | Question a survivor raises |
|---|---|---|
| `persistence` | `Repo.insert(cs)` → non-persisting `apply_action` | Does a test assert the write actually happened? |
| `on_conflict` | swap `on_conflict:` on `insert`/`insert!`/`insert_all` — `:nothing`→`:raise`, `:raise`→`:nothing`, `:replace_all`→`:nothing` | Is the conflict behaviour tested? |
| `validation_drop` | drop `validate_required`, `unique_constraint`, … | Is the rule it enforces tested? |
| `hook_drop` | drop `prepare_changes` / `optimistic_lock` | Is the side effect / lock asserted? |

Both query syntaxes are covered — the `from(u in User, where: …)` keyword form and the composable
pipe form (`q |> where([u], …)`) — as are direct, aliased, and `import`/`use`-bundled call styles.
Schema definitions (`schema`/`embedded_schema`) are left untouched: a mutated field name is a
broken schema, not an interesting mutant.

## Configuration

Each `{Mutare.Ecto, …}` entry takes:

```elixir
{Mutare.Ecto,
 repo: MyApp.Repo,                 # optional — identifies Repo.* calls
 families: :default,               # the default; or :all, a list, or {:default | :all, except: […]}
 dialects: [:postgres]}            # gate dialect-specific mutations (default: portable core)
```

- **`repo:`** — identify the Repo module for aggregate and write-call mutations. Omit it when only
  query/changeset families are needed; Repo-call families then produce no mutations.
- **`families:`** — select the catalog. Every family above is independently toggleable; an unknown
  name fails loudly. Accepts:
  - `:default` (the unset default) — every family **except** the opt-in `string_literal` /
    `atom_literal` / `boolean_literal` arms (see the † note above);
  - `:all` — every family, including those opt-in arms;
  - an explicit list, e.g. `[:comparison, :null_predicate]` (name the opt-in arms here to add them);
  - `{:default | :all, except: [families]}` — a base set minus exclusions; the easy way to disable a
    default-on arm, e.g. `{:default, except: [:integer_literal]}`.

  `Mutare.Ecto.families/0` returns the full set and `Mutare.Ecto.default_families/0` the default
  subset.
- **`dialects:`** — enable mutations that aren't portable across all adapters. The default `[]` is
  the portable core (safe on SQLite, Postgres, MySQL alike). `:postgres` adds `like`↔`ilike`;
  `:postgres`/`:mysql` add the `LEFT`↔`RIGHT` join swap (SQLite has no `RIGHT JOIN`).
- **`as:`** — rename the family in the report. List the plugin more than once with different
  `repo:`/`as:` to cover **multiple repos**, or different `families:`/`as:` to report a sub-family
  under its own name.

Unknown plugin option names raise an `ArgumentError`; `as:` is handled and removed by Mutare before
the remaining options reach this plugin.

## Equivalence reporting

Some survivors are honest signal rather than a flat "your test is missing." A surviving
`>=`↔`>`, `and`↔`or`, or `is_nil` mutant may be **legitimately unkillable without the right
fixture** — a boundary row, a `NULL`, an orphan — not an oversight. The plugin marks these families
and gives each a note naming the **specific** data a kill needs, so the report reads:

```
… SURVIVED  — kill may require a row whose value sits exactly on the bound — …
… SURVIVED  — kill may require NULL rows in the ordered column — …
… SURVIVED  — kill may require an orphan row — …
```

The reasons are distinct — a boundary value, NULL exclusion (`==`/`!=`), three-valued `and`/`or`,
NULL ordering, join cardinality — so the notes are too, rather than one catch-all string.

`Mutare.Ecto.equivalence_sensitive_families/0` returns that set, and with `as:` you can group them
under their own report name to separate "needs a boundary fixture" from "needs any test at all":

```elixir
# .mutare.exs
[
  mutators: [
    :all,
    {Mutare.Ecto, repo: MyApp.Repo, dialects: [:postgres],
     families: Mutare.Ecto.equivalence_sensitive_families(), as: :ecto_boundary_null},
    {Mutare.Ecto, repo: MyApp.Repo, dialects: [:postgres]}
  ]
]
```

Because the catalog is SQL-native, it also never emits the always-equivalent mutations (like
`x * 1`) that would otherwise inflate your denominator and dilute the score.
