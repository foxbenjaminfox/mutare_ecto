# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`mutare_ecto` is a mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), implemented as a
custom [Mutare](../mutare) mutator. It mutates the Ecto surface an app writes — `Repo` calls,
changeset pipelines, and the `from`/query DSL — and its load-bearing design rule is that it
**reuses none of Mutare's built-in mutation logic inside a query fragment** (the equivalence
reasoning would be Elixir's two-valued logic, not SQL's three-valued logic, silently
manufacturing false negatives), while reusing **all** of Mutare's plumbing (identity resolution,
selector/coverage/poison/Site machinery, and the delivery host).

`DESIGN.md` is the full blueprint and the source of truth for the rationale. Read `DESIGN.md`
before changing the catalog, routing, or delivery — the boundary decisions there are deliberate,
not incidental.

## Commands

```bash
mix test                                   # full suite (compiles ../mutare + this app first)
mix test test/mutare/ecto/query_test.exs   # one file
mix test test/mutare/ecto/query_test.exs:42 # one test by line
mix test test/mutare/ecto/semantic_test.exs # the only DB-backed file (boots SQLite)
mix format                                 # format (.formatter.exs)
mix deps.get                               # fetch deps
mix check                                  # quality gate: format-check + credo + dialyzer
```

`mix test` compiles everything, so there is no separate build step. The semantic suite spins up
its own SQLite-backed `MyApp.Repo` in `setup_all` (via `Mutare.Ecto.SemanticHarness.start_repo!/0`),
so every **other** test run stays DB-free and the `exqlite` NIF cost is isolated to that one file.

### `mix check` — the static-analysis gate

`mix check` is an alias (`aliases/0` in `mix.exs`) that runs three steps in order, aborting on the
first failure:

1. `mix format --check-formatted` — fails if any file isn't formatted (does not rewrite).
2. `mix credo` — lint via [Credo]; config in `.credo.exs` (`mix credo.gen.config` default).
3. `mix dialyzer` — discrepancy/type analysis via [Dialyxir] (the Mix wrapper over Erlang's
   Dialyzer).

Both tools are `only: [:dev, :test], runtime: false` deps and are never shipped. Dialyzer's PLTs
live in `priv/plts/` (gitignored, set via the `dialyzer:` key in `mix.exs`) so they can be cached
rather than rebuilt every run — the **first** `mix dialyzer` builds the PLT and takes a few minutes;
subsequent runs are fast. `mix check` runs in the default (`:dev`) env, so it analyzes `lib/`, not
the test-only fixtures.

[Credo]: https://github.com/rrrene/credo
[Dialyxir]: https://github.com/jeremyjh/dialyxir

## The `../mutare` path dependency

`mix.exs` pins `{:mutare, path: "../mutare"}`. Several features here required **new Mutare-core
extensions** (the selector host, `:routing`/`:hosted` macro routing, `{:keyword, …}` per-pair
routing, `:pinned` in-place delivery, the `Site` `note` channel). When a task needs core
machinery that doesn't exist yet, it is added to `../mutare`. Core's public test 
surface for plugins is `Mutare.Test` (wrapped here by `Mutare.Ecto.TestSupport`).

Deployment requirement: Mutare must run **as a dependency of the app under test** so Ecto and the
app's schemas are on the BEAM code path. This is what lets `use`-expansion expand `use Ecto.Schema`
(so `schema do … end` resolves and the `:skip` routing fires) and lets the host build valid
`dynamic` calls. Running against an external path degrades silently.

## Architecture

`Mutare.Ecto` (`lib/mutare/ecto.ex`) is a thin `Mutare.Mutator` front that **dispatches by the
node it sees** to a family of sub-mutators. It implements three core callbacks:

- `macros/0` — registers the compile-time DSL routing so core never splices a runtime selector
  into a query expression (which would poison the single build). `schema`/`embedded_schema` →
  `:skip`; the `from`/`where`/`having` family → `:routing`; the other query macros (`order_by`,
  `limit`, `select`, `join`, …) → `:skip` (but still offered to `mutate/2`).
- `macro_routing/1` and `host/2` — both delegate to `Mutare.Ecto.Host` (the selector host).
- `mutate/2` — gathers `{family, node}` pairs from every sub-mutator, then filters by the
  configured `families:`. Everything runs through `mutate/2` (not `mutate/1`) because all
  mutations read `context.opts`.

### The three delivery buckets (the spine of the design)

The surface divides by **how a mutation is delivered**, not by what it mutates:

1. **Plain calls** (`Bucket 1`) — `Repo.aggregate`, changeset validators, `Repo.insert`,
   `first`/`last`. Not DSL; resolved through `Mutare.Transform.Calls` (so direct/aliased/imported
   forms all match) and delivered by Mutare's ordinary in-place selector. Needs no new core
   machinery. Modules: `RepoAggregate`, `RepoWrite`, `Changeset`, `QueryTerminal`, plus the
   whole-`from` rewrites in `Query` and the standalone/pipe rewrites in `Clause`.
2. **Skipped** (`Bucket 2`) — `schema`/`embedded_schema` bodies. A mutated field name/type is a
   broken schema, not a mutant.
3. **Hosted DSL** (`Bucket 3`, the heart) — in-fragment `where`/`having` operator swaps (and the
   `sum`↔`avg`/`min`↔`max` aggregate swap inside a `having: sum(p.x) > n`). A query clause can't
   host a runtime `case`, so the host weaves each mutant behind Ecto's `^` + `dynamic` injection
   (`Mutare.Ecto.Host` + the SQL catalog in `Mutare.Ecto.Fragment`, plus `Mutare.Ecto.Aggregate`
   for the aggregate). Exactly one branch bakes into the compiled query per run, selected by
   `:persistent_term.get(:mutare_active, 0)`.

### Module map (`lib/mutare/ecto/`)

| Module | Role |
|---|---|
| `ecto.ex` | Dispatcher + `Mutare.Mutator` callbacks |
| `host.ex` | Selector host (#3): `macro_routing/1` + `host/2`, the `^`/`dynamic` weaving |
| `fragment.ex` | The **SQL-semantics catalog** for `where`/`having` conditions (Comparison, Connective, NullPredicate, Membership, FragmentLiteral, binding-reorder) |
| `binding_reorder.ex` | Positional binding-reorder (`[a, b]`→`[b, a]`) for the **other** binding-list macros (`select`/`order_by`/`join`/…), delivered in-place; `where`/`having` get theirs via the host. Named bindings are never moved |
| `query.ex` | Whole-`from` rewrites (clause drop, order flip, bound, join-type, `select`/`order_by` aggregate) |
| `clause.ex` | Standalone/pipe cousins of `query.ex` (`order_by`/`limit`/`offset`/`select`) |
| `ordering.ex` / `aggregate.ex` | Shared catalogs used by `query.ex`, `clause.ex`, and (aggregate) the `having` host |
| `repo_aggregate.ex` / `repo_write.ex` / `query_terminal.ex` | Bucket-1 Repo/query-function families |
| `changeset.ex` | Changeset pipeline drops (`:validation_drop`, `:hook_drop`) |
| `config.ex` | `families:`/`dialects:` reading + validation; equivalence-sensitive set + note |
| `ast.ex` | Small Sourceror AST helpers (literal wrapping, clean-meta emission) |

### Families and configuration

Every mutation is tagged with an SQL **family** (`config.ex` holds the canonical `:all` list).
`families:` narrows the catalog (unknown name fails loudly); `dialects:` gates non-portable
mutations (`like`↔`ilike` under `:postgres`; `LEFT`↔`RIGHT` join under `:postgres`/`:mysql` —
SQLite lacks `RIGHT JOIN`). Multi-repo and per-family report naming fall out of Mutare's `:as`
convention (list the plugin twice). The **equivalence-sensitive** families (`:comparison`,
`:connective`, `:null_predicate`, `:ordering_nulls`) carry a report `note` — a survivor reads
`… kill may require NULL/boundary data` — because their unkillability can be honest signal under
three-valued logic, not a test gap. The note currently renders inline only on the host delivery
path (`emit_hosted_site`).

## Conventions and gotchas

- **Never reuse a core mutator inside a query fragment.** This is the one rule the whole design
  exists to enforce (`DESIGN.md`, "The semantic boundary"). The fragment catalog is owned end to
  end in `fragment.ex`. Interpolated `^value` references are *Elixir* data → mutated by core's
  literal families; the SQL **structure/operators** are the plugin's.
- **Stay inside the single build.** Any in-query mutation must be delivered `^`-pinned behind the
  selector — a bare `case` in a query position poisons compilation. New query-position families go
  through the host, not the in-place selector.
- **Sourceror wraps literals** as `{:__block__, meta, [value]}`. Read values through the
  `AST.*_value/1` helpers, and emit fresh literals with **clean meta** (`AST.atom_literal/1` etc.)
  — reusing the original meta makes the renderer re-emit the old text even after the value changed
  (a silent no-op mutant).
- **Emitted module references are `Elixir.`-prefixed** (`Elixir.Ecto.Changeset.apply_action`,
  `Function.identity`). The metamutant recompiles in the author's aliasing scope, where a bare
  `Ecto.Changeset` could be retargeted by an `alias`; only the absolute name is poison-proof.

## Tests

- Unit tests (most files) drive `Mutare.transform_string/2` over fixture source strings and assert
  the recorded `Site`s (logical diffs + family names) and that the rendered metamutant compiles.
  Helpers: `Mutare.Ecto.TestSupport` (`diffs`, `ecto_diffs`, `assert_compiles`, `metamutant`).
  Test mutators **default to the Ecto plugin alone** (`{Mutare.Ecto, repo: MyApp.Repo}`), so
  recorded mutations are exactly the plugin's — pass `mutators: [:all, …]` to include core's.
- `semantic_test.exs` proves a recorded mutant is **live**: it compiles the metamutant, flips
  `:persistent_term`'s `:mutare_active` to a chosen mutant id (resolved from a Site's logical diff
  via `site_id/2`), runs the query against the seeded SQLite `MyApp.Repo`, and asserts the result
  set changed the way the mutation predicts. Fixtures: `test/support/myapp.ex` (schemas) and
  `test/support/seed.ex` (boundary/NULL rows chosen so each family is distinguishable).
- Because `Code.compile_string` is global, `TestSupport.uniquify_module/1` suffixes the top-level
  module name so `async` tests defining the same `defmodule` don't race the compiler.
</content>
</invoke>
