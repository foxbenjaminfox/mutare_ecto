# mutare_ecto

A mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), built as a custom
[Mutare](../mutare) mutator.

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
run, and its equivalence reasoning is SQL's, not Elixir's. (The full rationale is in
[`DESIGN.md`](DESIGN.md).)

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
expand and the query macros resolve. If Ecto isn't loadable, the plugin refuses loudly rather than
silently producing junk.

## Usage

Enable it in `.mutare.exs`, naming your Repo:

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
enables its mutations; `repo:` is what lets it recognise `Repo.*` calls regardless of how they're
aliased or imported.

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
| `fragment_literal` | `u.age > 18` → `19` / `17` / `0` | Off-by-one in a literal |
| `binding_reorder` | `a.x == b.y` → `b.x == a.y` | Are the two bindings distinguished? |
| `filter_drop` | drop a whole `where`/`having` clause | Is this filter tested at all? |

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
| `on_conflict` | `on_conflict: :nothing` → `:raise` | Is the conflict behaviour tested? |
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
 repo: MyApp.Repo,                 # required — identifies Repo.* calls
 families: :all,                   # or a subset, e.g. [:comparison, :null_predicate]
 dialects: [:postgres]}            # gate dialect-specific mutations (default: portable core)
```

- **`families:`** — narrow the catalog to a subset. Every family above is independently
  toggleable; an unknown name fails loudly. `Mutare.Ecto.families/0` returns the full set.
- **`dialects:`** — enable mutations that aren't portable across all adapters. The default `[]` is
  the portable core (safe on SQLite, Postgres, MySQL alike). `:postgres` adds `like`↔`ilike`;
  `:postgres`/`:mysql` add the `LEFT`↔`RIGHT` join swap (SQLite has no `RIGHT JOIN`).
- **`as:`** — rename the family in the report. List the plugin more than once with different
  `repo:`/`as:` to cover **multiple repos**, or different `families:`/`as:` to report a sub-family
  under its own name.

## Equivalence reporting

Some survivors are honest signal rather than a flat "your test is missing." A surviving
`==`↔`!=`, `and`↔`or`, or `is_nil` mutant on a nullable column may be **legitimately unkillable
without a `NULL` or boundary-value fixture** — that's three-valued logic, not an oversight. The
plugin marks these families so the report reads:

```
… SURVIVED  — kill may require NULL/boundary data
```

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

## Learn more

[`DESIGN.md`](DESIGN.md) is the full blueprint: the SQL-semantics boundary, how the `^`/`dynamic`
delivery host weaves a mutation into a query while keeping the single compile, and the routing that
tells query fragments apart from plain interpolated data.
</content>
