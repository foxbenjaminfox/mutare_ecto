# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  mutated, so no mutant can poison the single metamutant build.

[Unreleased]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare_ecto/releases/tag/v0.1.0
