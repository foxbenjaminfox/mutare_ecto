# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`validation_boundary`**, a changeset family: the strict/non-strict swap of a
  `validate_number/3` bound — `greater_than` ↔ `greater_than_or_equal_to`,
  `less_than` ↔ `less_than_or_equal_to` — the changeset counterpart of the in-query
  `comparison` swap, on by default and equivalence-sensitive (a kill needs a
  changeset whose value sits exactly on the bound). `equal_to`/`not_equal_to` are
  deliberately not swapped; `validate_length`'s inclusive `min`/`max` have no
  strict counterpart, so Mutare's integer family still provides their off-by-one mutations.

- **A standalone join written without a binding variable has its `on:` mutated.**
  `join(q, :inner, [p], "audit", on: p.id > 1)` (or a bare `subquery`, `fragment`,
  `^source` join — typically reached through its `as:` name) used to receive only
  its stage drop; its `on:` now gets the same in-query mutants as a named join's.

### Changed

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

- **A subquery in a `having` no longer breaks the instrumented build.** Ecto accepts
  `having: count(p.id) > subquery(…)` written statically but rejects the same subquery
  inside a *dynamic* `having` — and it rejects it when the query is built, not when the
  module compiles. Weaving such a clause therefore raised "subqueries are not allowed in
  `having` expressions" on every call of the function, the unmutated baseline included.
  A `having`/`or_having` whose condition carries a subquery (`subquery/1`, `exists`, `all`,
  `any`) now keeps its clause static: the same mutants are delivered as whole-call
  rebuilds. `where`/`or_where` accept the dynamic form and weave as before.

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

[Unreleased]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare_ecto/releases/tag/v0.1.0
