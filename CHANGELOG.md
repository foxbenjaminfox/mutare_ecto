# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Computed `from` sources retain their upstream mutants, in both direct and piped forms.
  Schema aliases, table names and source tuples now stay unmutated on the left of composable
  query stages, just as they do in direct calls.
- Piped binding declarations (`(p in Post) |> from(where: p.views > 5)`) supply their bindings
  to hosted conditions. Whole-call rewrites on this spelling are withheld until core supports
  delivering them without evaluating the declaration; hosted conditions and bounds still run.

### Changed

- **Mutare 0.3.0 or newer is required** (`{:mutare, "~> 0.3.0"}`) for the
  `Call.pipe_left` API used by source routing and binding discovery.

## [0.2.0] - 2026-09-17

### Added

- **`validation_boundary`**, a changeset family: the strict/non-strict swap of a
  `validate_number/3` bound — `greater_than` ↔ `greater_than_or_equal_to`,
  `less_than` ↔ `less_than_or_equal_to` — the changeset counterpart of the in-query
  `comparison` swap, on by default and equivalence-sensitive (a kill needs a
  changeset whose value sits exactly on the bound). `equal_to`/`not_equal_to` are
  deliberately not swapped; `validate_length`'s inclusive `min`/`max` have no
  strict counterpart, so Mutare's integer family still provides their off-by-one mutations.

- **`clause_drop` reaches a `from` keyword list.** `from(p in Post, group_by: …)`
  can now lose its `group_by:`, as `q |> group_by(…)` always could — likewise
  `distinct:`, `preload:`, `lock:`, `select_merge:`, `with_ties:` and the set
  operations (`union:`, `except:`, …), under the same `clause_drop` family.
  A `from` is compiled as one keyword list, so only a key the rest of the list
  cannot need is dropped: a join (other clauses read its binding), `select:`
  (a schemaless source requires one), `update:` and `windows:` are left alone.
  Expect more mutants on existing `from` queries.

- **`join_type` reaches a standalone join.** `join(q, :left, [p], c in Comment, on: …)`
  and `q |> join(:full, …)` now have their qualifier narrowed — `:left` → `:inner` and
  `:full` → `:left`, plus `:left` ↔ `:right` and `:full` → `:right` under
  `dialects: [:postgres]` or `[:mysql]` — exactly as a `from`'s `left_join:` key always
  was, under the same `# mutare:ignore[ecto:left]` labels. Only a written qualifier is
  swapped, never a computed one.

- **A standalone join written without a binding variable has its `on:` mutated.**
  `join(q, :inner, [p], "audit", on: p.id > 1)` (or a bare `subquery`, `fragment`,
  `^source` join — typically reached through its `as:` name) used to receive only
  its stage drop; its `on:` now gets the same in-query mutants as a named join's.

### Changed

- **Mutare 0.2.1 or newer is now required** (`{:mutare, "~> 0.2.1"}`, raised from
  `~> 0.1`). Sourceror 1.12.3 corrected two range over-counts that Mutare had
  compensated for, so against an older Mutare the compensation double-corrects: a
  mutant whose range ends at a bare `true`/`false`/`nil` renders its diff one
  character short (`where: :mutatede`), and the JSON/SARIF reporters emit the
  short `endColumn`. Mutare 0.2.1 drops the compensation and floors Sourceror to
  match. Only a survivor's reported location was ever affected — never which
  mutants are generated, nor how they behave.

- **The README states what each query spelling gets, instead of "both syntaxes are
  covered".** Most families reach the same mutated queries from a `from` keyword
  list and from composable stages, but not all: a join, a `select` and a
  `windows` drop from a pipeline only, a computed query is
  mutated under `where(recent(2), …)` and not under `from p in recent(2)`, and a
  schema or table name on a pipe's left (`Post |> where(…)`) is not held back from
  Mutare's own families. The new "Coverage by spelling" section lists these, along
  with two placement effects — only an inline `from` subquery is entered, and a
  `^` pin's interior is mutated inside a condition only — and what a dropped stage
  does when a later stage depended on it. Each row is pinned by a test.

- **Changeset stages are routed.** Listing the plugin now holds back from Mutare's
  core families the changeset positions where a core swap is a crash rather than
  a mutant: a written field atom (`validate_length(cs, :name, …)` — swapping it
  names a field Ecto raises on), the option keys of `validate_number`
  (`greater_than:`, `message:`, … — Ecto rejects unsupported options), and
  a written `count:` mode of `validate_length` (`:mutare` is no mode Ecto
  dispatches on). Core still mutates `validate_length`'s *keys*: Ecto ignores an unknown
  key, so `min:` → `mutare:` is a live mutant — that one bound gone, the call
  otherwise intact — finer than the whole-call drop. The bound *values* still
  receive core's literal mutants, and a field *list*
  (`validate_required(cs, [:name, :email])`) stays an ordinary expression for
  core's list families.

- **An unnamed `assoc` join follows the `assoc` rule.** The `on:` of an
  `assoc` join is left to the whole-query families, never mutated in place — but
  the rule recognised only `c in assoc(p, :posts)`, so a `from` join written as a
  bare `assoc(p, :posts)` had its `on:` mutated in place all the same. Both
  spellings are now treated alike.

### Fixed

- **A `from` join written without a binding variable no longer shifts the bindings
  of the joins around it.** Ecto binds `cross_join: "audit"` (or a bare `subquery`,
  `fragment`, `assoc`, `^source` join) anonymously and still counts it, but the
  binding list the plugin re-declares for a hosted `where`/`having`/`on:` left it
  out — so in `from p in "posts", cross_join: "audit", join: c in "comments", …`
  a condition on `c` was resolved against `"audit"`. That held for every branch of
  the woven selector, the unmutated one included: where the two tables share the
  column the condition reads, the instrumented query ran without error and
  returned the wrong rows, so tests could fail (or mutants be misjudged) under
  Mutare that pass without it. An unnamed join is now re-declared as `_`
  (`[p, _, c]`; `[p, ..., c, _]` when the source is a composed query).
- **Live mutants beneath `is_nil` are no longer pruned.** Every mutant inside an
  `is_nil(...)` argument except the coalesce drop used to be suppressed as
  equivalent, on the claim that value mutations preserve NULL-ness. They do only
  for some forms. A mutant there is now pruned only when it is *known* to be NULL
  on exactly the original's rows — a literal bump, `+`↔`-`, `sum`↔`avg`/`min`↔`max`,
  beneath `+`/`-`/`*`, `coalesce` and the aggregates — and everything else is
  offered: `*`↔`/` (a zero divisor is NULL on SQLite and MySQL), `and`↔`or`, a
  literal or swap inside a `fragment(...)`
  (`is_nil(fragment("NULLIF(?, ?)", p.score, 0))`), a JSON path key, a divisor.
  A `^` pin beneath `is_nil` is now handed to Mutare's core families like any
  other pin (`^(opts[:min] || default)` can turn `nil`). Expect new mutants on
  such conditions; a plain `is_nil(p.column)` is unchanged.
- The `*`↔`/` survivor note no longer says a zero divisor always raises: it
  raises on Postgres and yields NULL on SQLite and MySQL.
- **A condition that is itself a `^` pin keeps Ecto's own handling when
  instrumented.** With Mutare's core families enabled, a root interpolation
  carrying mutable Elixir — `where: ^[score: 5]`, or a computed
  `^(if enabled?, do: [active: true], else: [])` — was woven behind a
  `dynamic/2` wrap like any other condition. Ecto reads a root interpolation by
  its value (a keyword list is a field filter, a boolean a literal condition),
  but inside `dynamic/2` the same pin is a plain parameter, so the instrumented
  query raised `Ecto.QueryError` even with no mutant active. Such a condition is
  now woven pin-only over its interior, leaving Ecto's dispatch untouched; the
  reported diffs are unchanged. A pin holding a bare variable (`^filters`) or a
  dynamic was never affected.

- **A subquery in a `having` no longer breaks the instrumented build.** Ecto accepts
  `having: count(p.id) > subquery(…)` written statically but rejects the same subquery
  inside a *dynamic* `having` — and it rejects it when the query is built, not when the
  module compiles. Weaving such a clause therefore raised "subqueries are not allowed in
  `having` expressions" on every call of the function, the unmutated baseline included.
  A `having`/`or_having` whose condition carries a subquery (`subquery/1`, `exists`, `all`,
  `any`) now keeps its clause static: the same mutants are delivered as whole-call
  rebuilds. `where`/`or_where` accept the dynamic form and weave as before.
- **A binding declaration the plugin could not read no longer breaks the build.**
  Ecto accepts an interpolated binding name (`where(q, [{^name, p}], …)`) and an
  explicit index (`where(q, [{p, 0}, {c, 2}], …)`); the plugin read neither, took
  the declaration for an absent one, and hosted the condition behind
  `dynamic([], p.score > 10)` — an unbound `p`, failing the single build. As a
  `from` source (`from([{p, 0}] in query, …)`) the same list crashed the run
  outright. Both forms (and the tuple spelling `[{:post, p}]`) are now read and
  re-declared as written. A condition under a declaration still outside the
  grammar — a computed index, or a name that calls a function, either of which
  the re-declaration would evaluate a second time — gets the same mutants,
  delivered as rebuilds of the whole call under the declaration as written; a
  condition that is itself a `^` pin re-declares nothing, and is woven as usual.
- **Several entries over a literal source no longer misplace its joins.**
  `from([p, q] in Post, join: c in Comment, …)` re-declared `[p, q, c]`, placing
  `c` at a binding that does not exist; it is now tail-anchored (`[p, q, ..., c]`).

- **A keyword-shorthand condition is never hosted as a predicate.** Two shapes
  were: a shorthand written after a binding list (`where(q, [p], score: 5)`), and
  a shorthand in a `from` whose sibling is hosted
  (`from(p in "posts", where: [score: 5], limit: 10)` — also a join's
  `on: [score: 5]`). The list was wrapped in `dynamic/2`, which rejects keyword
  pairs, so the instrumented build failed to compile; the weave also displaced
  Mutare's own `^`-pinned mutants of the pair values, and with the opt-in
  `atom_literal` family on, the column key itself was renamed.
  Routing and hosting now share one classification, so a shorthand's values are
  Mutare's to mutate, per pair, whatever else the call contains. Inside an inline
  subquery (`exists(from c in "comments", where: [score: 5])`) the pair values
  keep their mutants and the column key is no longer renamed.

- **A structural name keeps its protection behind a `^` pin.** A literal at a
  structural position — the column of `field/2`, a cast type, an interval unit, a
  binding or select-alias name — is never mutated when written into the query.
  The same literal interpolated (`field(p, ^:score)`, `ago(^n, ^"day")`,
  `type(^v, ^:integer)`, `selected_as(^:total)`, a fragment's
  `identifier(^"und")`) was handed to Mutare's core families as ordinary data and
  swapped for a sentinel: an unknown column, or a unit Ecto rejects when the
  query is built — a broken query under that mutant, not a test signal. An
  interpolated value now keeps the role of the position it fills. A literal that
  *is* the name — written directly, or as a `||` default or an
  `if`/`case`/`cond` branch — is left alone; the Elixir that *computes* a name (the
  condition choosing a column, a lookup key) still mutates. Conversely, the
  protection of a pinned keyword filter's column keys (`where: ^[score: 5]`) now
  applies only where Ecto reads a keyword list as a filter: an option list inside
  an ordinary interpolated value (`p.score > ^lookup(n, scope: :all)`) gets
  Mutare's usual mutants again.

## [0.1.1] - 2026-09-07

### Fixed

- **No compiler warning on Elixir 1.20.** The host routing re-checked the
  literal kinds `Mutare.AST.literal_value/1` already guarantees, which 1.20's
  type inference reports as a test that always succeeds while compiling the
  dependency (and which failed the package's own warnings-as-errors CI). The
  redundant check is gone; behaviour is unchanged.
- **The README's install snippet names real versions** (`~> 0.1` for both
  `mutare` and `mutare_ecto`) instead of the `"~> ..."` placeholders left
  from before publication.

## [0.1.0] - 2026-09-07

Initial release.

### Added

- **An SQL-semantics mutation catalog** for the Ecto surface, independent of
  Mutare's Elixir-semantics built-ins: every mutation is one a real SQL engine
  will run, and equivalence reasoning follows SQL's three-valued logic.
- **In-condition families** (delivered through `^`/`dynamic` injection so the
  query still compiles once): `comparison`, `null_predicate`, `connective`,
  `membership`, `arithmetic`, `coalesce`, `temporal`, `integer_literal`,
  `float_literal`, the opt-in `string_literal`/`atom_literal`/`boolean_literal`
  arms, `binding_reorder`, and `filter_drop`.
- **Query-shape families**: `ordering`, `ordering_nulls`, `bound`, `join_type`,
  `combination`, `aggregate`, `clause_drop`, and `query_terminal`.
- **Repo-write and changeset families**: `persistence`, `on_conflict`,
  `validation_drop`, and `hook_drop`.
- **Both query syntaxes** — the `from` keyword form (piped too) and the
  composable pipe form — across direct, aliased, and `import`/`use`-bundled
  call styles; schema definitions are left untouched.
- **Configuration** per `{Mutare.Ecto, …}` entry: `repo:` (Repo-call
  recognition — one module or a list), `families:` (`:default`, `:all`, an explicit list, or
  `{base, except: […]}`), `dialects:` (portable core by default; `:postgres` /
  `:mysql` gate dialect-specific swaps), and `as:` report renaming.
- **Equivalence reporting**: boundary/NULL-sensitive families annotate each
  survivor with the specific fixture data a kill would need
  (`Mutare.Ecto.equivalence_sensitive_families/0`).
- **Structural-position safety**: literals that shape the SQL (fragment
  templates, interval units, cast types, field/binding names) are never
  mutated, so these positions cannot cause the single metamutant build to fail.

[Unreleased]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare_ecto/releases/tag/v0.1.0
