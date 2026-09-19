# mutare_ecto

[![Hex.pm](https://img.shields.io/hexpm/v/mutare_ecto.svg)](https://hex.pm/packages/mutare_ecto)
[![Hexdocs](https://img.shields.io/badge/hexdocs-docs-blue.svg)](https://hexdocs.pm/mutare_ecto)
[![CI](https://github.com/foxbenjaminfox/mutare_ecto/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/foxbenjaminfox/mutare_ecto/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/mutare_ecto.svg)](https://github.com/foxbenjaminfox/mutare_ecto/blob/master/LICENSE)

A mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), built as a custom
[Mutare](https://github.com/foxbenjaminfox/mutare) mutator.

Mutation testing checks how good your tests actually are: it makes small, deliberate changes to
your code — a `>` becomes a `>=`, a `where` clause is dropped, a `validate_required` is removed —
and reruns your suite. If the tests still pass, that mutation **survived**, and you've found a gap
your assertions don't cover.

`mutare_ecto` applies mutation testing to the Ecto code you write — `Repo` calls, changeset
pipelines, and the `from`/query DSL. A surviving mutant indicates that no test fails when a
particular filter, sort order, or validation changes.

## Why a dedicated Ecto mutator

An Ecto `where` condition uses Elixir syntax to express SQL, which evaluates boolean expressions
under **three-valued logic** (`NULL` is neither true nor false). Elixir's equivalence rules do not
account for SQL's NULL handling. Applying them to query conditions can suppress useful mutations
or produce equivalent ones.

So `mutare_ecto` provides a separate SQL-semantics mutation catalog and never applies Mutare's
Elixir-semantics mutators inside a query. Every mutation it emits is one a real SQL engine will
run, and its equivalence rules follow SQL semantics.

## Installation

Add both Mutare and this plugin to the app you want to test, in `:dev`/`:test`:

```elixir
# mix.exs
defp deps do
  [
    {:mutare, "~> 0.3.0"},
    {:mutare_ecto, "~> 0.2"}
  ]
end
```

It must run **as a dependency of the app under test** (not against an external source path), so
your `Repo` and schemas are loadable in the Mutare process — that's what lets `use Ecto.Schema`
expand and the query macros resolve. External-source operation is unsupported: the plugin declares
the Ecto surface it needs (`Ecto.Schema`/`Ecto.Query`) via `Mutare.Ecto.required_modules/0`, and
Mutare checks it once at startup, aborting with a `Mutare.EnvironmentError` when a module is not
loadable. Beyond that guard, unresolved target-app modules can still make routing incomplete or
invalid.

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
enables its mutations; `repo:` (one module, or a list when the app has several) is optional for
query and changeset mutations, and is what lets it recognise `Repo.*` calls regardless of how
they're aliased or imported.

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
| `membership` | `x in ^list` → `x not in ^list`; `exists(…)` → `not exists(…)`; `x in [a, b]` → `x in [b]`; `like` → `ilike` | Polarity / set membership / case-sensitivity |
| `arithmetic` | `u.a + u.b` → `u.a - u.b`; `*` ↔ `/` (also in `select`/`order_by` values) | Does the computed value matter? |
| `coalesce` | `coalesce(u.x, 0)` → `u.x` (also in `select`/`order_by` values) | Is the NULL fallback exercised? |
| `temporal` | `ago(3, "day")` ↔ `from_now(3, "day")` | Does a row near *now* pin the direction? |
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
`datetime_add`/`date_add`/`from_now`/`ago`, the cast type of `type/2`, the name in `field/2`,
`as/1`/`parent_as/1`, or `selected_as` — is never mutated (it shapes the SQL, so a mutant would
just be a broken query, not a test signal). An interpolated name is covered too: in
`field(u, ^(sort || :inserted_at))` Mutare's core families mutate the Elixir that computes the
name, never a literal that is the name.

**Query shape** — ordering, pagination, joins, aggregates, and the query terminals:

| Family | Example |
|---|---|
| `ordering` | `order_by: [asc: u.name]` → `[desc: u.name]` |
| `ordering_nulls` | `:asc_nulls_first` → `:asc_nulls_last` |
| `bound` | `limit: 10` → `9` / `11`, or drop the `limit`/`offset` |
| `join_type` | `left_join:` → `inner_join:`, `full_join:` → `left_join:`/`right_join:`; likewise `join(q, :left, …)` → `join(q, :inner, …)` (narrows cardinality) |
| `combination` | `intersect` ↔ `except`, `intersect_all` ↔ `except_all` (`union` is left alone) |
| `aggregate` | `sum(u.x)` ↔ `avg(u.x)`, `min` ↔ `max` (in `select`/`order_by`/`having`, or `Repo.aggregate`) |
| `clause_drop` | drop a clause that is neither a filter nor a bound — a pipe stage (`q \|> group_by(…)`, `\|> select(…)`, `\|> join(…)`, … → `q`) or a `from` key (`group_by:`, `distinct:`, `preload:`, …); never `order_by`: an unordered result has no defined order to test |
| `query_terminal` | `Ecto.Query.first` ↔ `last` |

**Repo writes and changesets** — plain calls, no query DSL involved:

| Family | Example | Question a survivor raises |
|---|---|---|
| `persistence` | `Repo.insert(cs)` → non-persisting `apply_action` | Does a test assert the write actually happened? |
| `on_conflict` | swap `on_conflict:` on `insert`/`insert!`/`insert_all` — `:nothing`→`:raise`, `:raise`→`:nothing`, `:replace_all`→`:nothing` | Is the conflict behaviour tested? |
| `validation_drop` | drop `validate_required`, `unique_constraint`, … | Is the rule it enforces tested? |
| `validation_boundary` | `validate_number(:age, greater_than: 0)` → `greater_than_or_equal_to: 0` (and `less_than` ↔ `less_than_or_equal_to`) | Is the bound itself tested? |
| `hook_drop` | drop `prepare_changes` / `optimistic_lock` | Is the side effect / lock asserted? |

Direct, aliased, and `import`/`use`-bundled call styles are all recognised.
Schema definitions (`schema`/`embedded_schema`) are left untouched: a mutated field name is a
broken schema, not an interesting mutant. For the same reason, listing the plugin holds a few
changeset positions back from Mutare's core families: a stage's written field atom
(`validate_length(cs, :name, …)` — an unknown field raises), `apply_action`'s action atom, the
option *keys* of `validate_number` (an unknown option raises; `validation_boundary` swaps strict
and non-strict keys, and core still mutates the bound *values*), and a written `count:` mode
of `validate_length`. Core still mutates its *keys*: Ecto ignores an unknown one, so `min:` → `mutare:`
is a live mutant — that bound alone gone.

### Coverage by spelling

Ecto lets one query be written as a `from` keyword list (piped too:
`User |> from(as: :u, where: …)`) or as composable stages (`q |> where([u], …)`, or the same
calls written directly, `where(q, [u], …)`). Most families reach the same mutated queries either
way; the differences below mean that respelling some queries changes which mutants they get.

| | `from` keyword form | composable stages |
|---|---|---|
| A condition (`where`/`having`/`or_*`, a join's `on:`): every in-condition family, `filter_drop`, keyword-shorthand values | ✓ | ✓ |
| `bound`, `ordering`, `ordering_nulls`, `join_type`, `combination`; `aggregate`/`arithmetic`/`coalesce` in a `select`/`order_by` | ✓ | ✓ |
| `binding_reorder` | the source list (`from [a, b] in q`), which every clause reads | each stage's own list |
| `clause_drop` | ✓ `group_by:`, `distinct:`, `preload:`, `lock:`, `select_merge:`, `with_ties:`, a set operation; ✗ a join, `select:`, `update:`, `windows:` — the rest of the keyword list may need them, and it is compiled as a whole | ✓ each of those, and `with_cte` |
| The query being refined, when computed — `recent(2)` | ✓ `from(recent(2), …)` and `recent(2) \|> from(…)`; ✗ inside a binding declaration (`from p in recent(2)`) | ✓ `where(recent(2), …)` and `recent(2) \|> where(…)`: Mutare's own families mutate it |
| The query being refined, when a schema or table name | held back from Mutare's families (a swapped name is a broken query) | held back in both direct and piped calls (`where(Post, …)`, `Post \|> where(…)`) |

A binding declaration piped into `from`, such as `(p in User) |> from(where: p.age > 18)`,
gets hosted condition and literal-bound mutations. Whole-call rewrites (clause drops, ordering
flips and source binding reorders) are currently withheld for that spelling.

Where an expression is written matters as well:

- **A subquery's interior** is mutated when it is an inline `from` inside a condition
  (`p.id in subquery(from c in …)`, `exists(from …)`). Composed stages retain upstream
  mutations: `subquery(Comment |> where(…) |> select(…))` mutates the `where`. The final
  stage's own clauses (`where` in `subquery(Comment |> where(…))`) and a subquery inside a
  `from` binding (`from s in subquery(…)`) are not entered. Built first and passed by
  variable, the subquery is an ordinary query and gets every family.
- **A `^` pin's interior** is ordinary Elixir, which Mutare's own families mutate when the pin
  sits in a condition (`where: p.views > ^(min + 1)`). In any other clause — `limit:
  ^(page_size + 1)`, `order_by: ^[asc: dynamic(…)]`, a `select` — the interior is left alone. An
  expression or a `dynamic` bound to a variable first is mutated where it is built; the same
  code written inside such a pin is not.

**A dropped stage can break the query rather than weaken it.** `q |> join(…)` → `q` is the query
without the join only when nothing later needs what the stage provided. When a later stage
does — the join's binding, a `windows` name an `over/2` uses, the `limit` a `with_ties`
qualifies, a CTE a join reads, a schemaless source's `select` — the mutant raises as the query
is built, planned, or run. Any test that executes the query kills it, whatever that test
asserts: the kill shows that the stage runs, not that its effect is tested. A pipeline is
assembled at runtime, often across functions, so a single stage cannot show which case it is
in. (Dropping a join ahead of another also runs, with the later positional bindings shifted
onto the freed slot.) A `from` key drops only where nothing in the same `from` can need it, so
the query without it always compiles — though the engine may still object, as Postgres does to
a `select` that mixes an aggregate with a plain column once its `group_by:` is gone.

## Configuration

Each `{Mutare.Ecto, …}` entry takes:

```elixir
{Mutare.Ecto,
 repo: MyApp.Repo,                 # optional — identifies Repo.* calls; a module or a list
 families: :default,               # the default; or :all, a list, or {:default | :all, except: […]}
 dialects: [:postgres]}            # gate dialect-specific mutations (default: portable core)
```

- **`repo:`** — identify the Repo module for aggregate and write-call mutations — one module, or a
  list (`repo: [MyApp.Repo, MyApp.ReplicaRepo]`) when the app has several. Omit it when only
  query/changeset families are needed; Repo-call families then produce no mutations.
- **`families:`** — select the catalog. Every family above is independently toggleable; an unknown
  name raises an `ArgumentError`. Accepts:
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
  `families:`/`as:` to report a sub-family under its own name, or different `repo:`/`as:` to report
  each repo's mutants separately (a single `repo: [A, B]` entry reports both as `ecto`).

Unknown plugin option names raise an `ArgumentError`; `as:` is handled and removed by Mutare before
the remaining options reach this plugin.

## Equivalence reporting

A surviving `>=`↔`>`, `and`↔`or`, or `is_nil` mutant may require **specific fixture data** to
distinguish it from the original — a boundary row, a `NULL`, an orphan. The plugin annotates these
families with the specific data needed to kill each mutant, so the report reads:

```
… SURVIVED  — kill may require a row whose value sits exactly on the bound — …
… SURVIVED  — kill may require NULL rows in the ordered column — …
… SURVIVED  — kill may require an orphan row — …
```

The reasons are distinct — a boundary value, NULL exclusion (`==`/`!=`), three-valued `and`/`or`,
an arithmetic identity operand (0 for `+`/`-`, ±1 for `*`/`/`), a NULL row for the `coalesce`
default, a near-*now* row for the `ago`/`from_now` flip, NULL ordering, join cardinality, a
changeset value on a `validate_number` bound — so the notes are too, rather than one catch-all
string.

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
