# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
It is a **map, not a manual**: each rule below is stated once, in the module that owns it, and
only pointed at from here (see [Conventions and gotchas](#conventions-and-gotchas), last bullet).

## What this is

`mutare_ecto` is a mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), implemented as a
custom [Mutare](../mutare) mutator. It mutates the Ecto surface an app writes — `Repo` calls,
changeset pipelines, and the `from`/query DSL.

Its load-bearing design rule: **reuse none of Mutare's built-in mutation logic inside a query
fragment** (core reasons in Elixir's semantics, not SQL's) while reusing **all** of Mutare's
plumbing. The SQL half is `Mutare.Ecto.Fragment`'s; the `^`-pin half is `Mutare.Ecto.Island`'s.

## Commands

```bash
mix test                                     # full suite (compiles ../mutare + this app first)
mix test test/mutare/ecto/query_test.exs     # one file
mix test test/mutare/ecto/query_test.exs:42  # one test by line
mix test test/mutare/ecto/semantic_test.exs  # the only DB-backed file (SQLite by default)
MUTARE_TEST_POSTGRES=1 mix test              # also run the semantic suite against Postgres
mix format                                   # format (.formatter.exs)
mix check                                    # quality gate: format-check + credo + dialyzer
mix docs                                     # ExDoc → doc/ (gitignored)
mix deps.get                                 # fetch deps
```

`mix test` compiles everything, so there is no separate build step. Only the semantic suite
touches a DB — it boots its Repo in `setup_all` (via `Mutare.Ecto.SemanticHarness.start_repo!/1`),
so every **other** test run stays DB-free and the driver NIF cost is isolated to the semantic
modules.

### The semantic suite's engines (SQLite always, Postgres opt-in)

- The DB-backed suite lives in a `use`-able template (`Mutare.Ecto.SemanticCases`) that the entry
  file (`semantic_test.exs`) instantiates **once per enabled engine** — one test module per
  engine, each with its own `@repo` — so a single `mix test` covers one engine or two.
- SQLite (`MyApp.Repo` / `ecto_sqlite3`, a self-contained temp file) is always on and is the
  default. `MUTARE_TEST_POSTGRES=1` generates a *second* module (`…SemanticTest.Postgres`) that
  runs the identical fixtures against `MyApp.PgRepo` (`postgrex`) and a running server.
- Two engines need two Repo **modules** because Ecto bakes a Repo's adapter in at compile time
  (`put_dynamic_repo` switches connections, not adapters). Both modules compile unconditionally;
  the Postgres one stays inert unless its test module is generated.
- The switch is read at the test file's compile time — and test `.exs` files recompile every run —
  so flipping the var takes effect immediately, no forced rebuild.
- Postgres connection config comes from the standard `PG*` env vars
  (`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`, with local defaults; the harness
  `storage_up`s the database if missing).
- CI runs Postgres on the whole **`ecto` version matrix** (every supported Ecto line), so any
  change in Ecto's Postgres-only handling is caught; the elixir/otp `test` sweep stays
  SQLite-only (the non-semantic tests never touch a DB).

### `mix check` — the static-analysis gate

An alias (`aliases/0` in `mix.exs`) that runs three steps in order, aborting on the first failure:

1. `mix format --check-formatted` — fails if any file isn't formatted (does not rewrite).
2. `mix credo` — lint via [Credo]; config in `.credo.exs` (`mix credo.gen.config` default).
3. `mix dialyzer` — discrepancy/type analysis via [Dialyxir] (the Mix wrapper over Erlang's
   Dialyzer).

Both tools are `only: :dev, runtime: false` deps, never shipped or fetched by test jobs.
Dialyzer's PLTs live in `priv/plts/` (gitignored, set via the `dialyzer:` key in `mix.exs`) so
they can be cached rather than rebuilt every run — the **first** `mix dialyzer` builds the PLT and
takes a few minutes; subsequent runs are fast. `mix check` runs in the default (`:dev`) env, so it
analyzes `lib/`, not the test-only fixtures.

[Credo]: https://github.com/rrrene/credo
[Dialyxir]: https://github.com/jeremyjh/dialyxir

## The `../mutare` path dependency

`mix.exs` uses `{:mutare, path: "../mutare"}`, so both local development and CI use the sibling
checkout (until Mutare is published to Hex). When a task seems to need core machinery that doesn't
exist yet, extending `../mutare` is an **option**, not the default — **consult the user before
adding anything to core** (the alternatives: a plugin-side approach, or narrowing the task).
Core seams that have gone that route after such a decision:

- the selector host (`Mutare.Mutator.MacroHost`) and `:routing`/`:hosted` macro routing;
- `{:keyword, …}` per-pair routing and `:interpolated` in-place delivery;
- the `Site` `note` channel;
- the plugin-config toolkit (`c:Mutare.Mutator.init/1` + `use Mutare.Mutator.Families`);
- `:mutators` threaded into a registered macro's whole-call `mutate/2` offer — the island
  sub-contract seam over the run's full spec set, with a nested host's targets lowered to
  whole-call rebuilds in collect (NOTES "Inner `from` inside a pin interior: whole-call rewrites only, no condition swaps");
- `c:Mutare.Mutator.finalize/2`, run by core on both delivery paths;
- `c:Mutare.Mutator.required_modules/0`, the environment guard;
- the shared `:structural` argument-mark label (`Mutare.Mutator.structural_label/0`/`pinned?/1`);
- `Mutare.AST.numeric_alternatives/3`, the off-by-one/zero table the literal arms share with core.

Core's public test surface for plugins is `Mutare.Test`, wrapped here by
`Mutare.Ecto.TestSupport` (threads the plugin's default mutators, forwards every other option).
The suites also use core's `observe_mutant/3` flip-and-compare and the shipped
`Mutare.Test.Fixtures.RoutingExtension` for foreign-routing composition.

**Deployment requirement:** Mutare must run **as a dependency of the app under test** so Ecto and
the app's schemas are on the BEAM code path (that is what lets `use`-expansion expand
`use Ecto.Schema` and the host build valid `dynamic` calls). External-source operation is
unsupported: `required_modules/0` declares the Ecto surface and core aborts with a
`Mutare.EnvironmentError` at startup when it is missing. Beyond that guard, unresolved target-app
modules can still make routing incomplete or invalid.

**CI's `ecto` job** is a compatibility matrix that runs the complete suite against **every
supported Ecto minor line** — from the declared minimum (`3.12`, floor-pinned) through each line
up to the latest published release — by overriding `ECTO_REQUIREMENT`, `ECTO_SQL_REQUIREMENT`, and
`ECTO_SQLITE3_REQUIREMENT` per matrix entry (the SQL/SQLite drivers are pinned to the matching
line because their versions track Ecto's). A final entry builds against the **development tip** of
Ecto via `ECTO_GIT_BRANCH` (which makes `mix.exs` swap to git checkouts of `ecto`/`ecto_sql`); it
is `continue-on-error: true`, so upstream breakage warns without failing the run. `MIX_LOCKFILE`
gives each entry its own isolated generated lockfile; normal local commands continue to use
`mix.lock`. When a new Ecto minor is published, add a matrix entry in
`.github/workflows/ci.yml`.

## Architecture

`Mutare.Ecto` (`lib/mutare/ecto.ex`) is a thin `Mutare.Mutator` front that also implements core's
two adapter behaviours, `Mutare.MacroRouting` and `Mutare.Mutator.MacroHost`. Every callback
delegates: `init/1` → `Mutare.Ecto.Config` (options parsed once, delivered as `context.config`);
`macro_routes/0`/`hosted_macros/0` are derived from `Mutare.Ecto.Surface`; `route_arguments/2` →
`Mutare.Ecto.Host.Routing`; `host/2` → `Mutare.Ecto.Host`; `mutate/2` → `Mutare.Ecto.Dispatcher`
(tags → `Mutare.Ecto.Tag.to_mutation/1`); `finalize/2` → `Mutare.Ecto.Equivalence` (the one
filter + note funnel); `argument_marks/1` pins `apply_action`'s action atom
(NOTES "`apply_action`'s action atom: pinned against core's value families, never mutated").
Each core→plugin boundary — `Dispatcher`, `Host.host/2`, `finalize/2` — unpacks core's context
**once** into the plugin-owned `%Mutare.Ecto.Context{}` (`Mutare.Ecto.Context`), the one reader of
core's map; every producer inside sees only that struct.

### The three delivery buckets (the spine of the design)

The surface divides by **how a mutation is delivered**, not by what it mutates:

1. **Plain calls** — resolved through `Mutare.Calls`, delivered by Mutare's ordinary in-place
   selector: `RepoAggregate`, `RepoWrite`, `Changeset`, `QueryTerminal`; the whole-`from`
   rewrites (`Query`); the standalone/pipe rewrites (`Clause`, `ClauseDrop`, `BindingReorder`);
   and the free-standing `dynamic/1,2`, mutated whole-call where it is built (`Dynamic`).
2. **Skipped** — `schema`/`embedded_schema` bodies: a mutated field name/type is a broken schema,
   not a mutant.
3. **Hosted DSL** (the heart) — in-fragment `where`/`having`/`on:` mutations, woven behind Ecto's
   `^`/`dynamic` injection because a query clause can't host a runtime `case`; exactly one branch
   bakes into the compiled query per run (`:persistent_term.get(:mutare_active, 0)`). `Host`
   coordinates; `Fragment` is the SQL catalog (`Scalar`/`Aggregate` folded in per node);
   `Island` sub-contracts each `^` pin's interior to core; `Subquery` recurses into an inline
   subquery; `Bound` is the pin-only bound bump.

### Module map (`lib/mutare/ecto/`)

Each row is role + the rule(s) that module is the **home** for.

| Module | Role |
|---|---|
| `ecto.ex` | the `Mutare.Mutator`/`MacroRouting`/`MacroHost` front (see Architecture above) and the public configuration doc (`families:`/`dialects:`/`repo:`/`as:`) |
| `dispatcher.ex` | unpacks core's context into `%Context{}`, classifies a node once, and invokes only the relevant sub-mutators |
| `surface.ex` | the one descriptor table for every owned query macro / `from` key (routing kind, capabilities, drop families); home of the macro-kind taxonomy and its dispatch-exhaustiveness rule (`macro_kinds/0`) |
| `sub_mutator.ex` | the `mutations(node, %Context{})` behaviour every producer implements |
| `context.ex` | `%Context{config, pipe_mode, mutators}`, the plugin's view of core's callback context; home of the unpack-once boundary rule (`new/1` is the only reader of core's map, and the struct is total, so no producer guards a context shape) |
| `tag.ex` | `%Tag{family, node, label, attribution}` — the one shape every producer emits; `to_mutation/1`; home of what the `attribution` field means |
| `host.ex` | selector-host coordinator (bucket 3): a hosted call → `Target`s |
| `host/routing.ex` | `route_arguments/2`, the per-argument classifier; home of the routing rationale (`:hosted`/`:expression`/`:skip`/`:interpolated`/`{:keyword, …}`) |
| `host/condition.ex` | `locate/1`; home of the hosted-condition shapes (binding-form / binding-less / keyword-shorthand) |
| `host/bindings.ex` | interprets binding declarations and renders the list a woven `dynamic/2` re-declares |
| `host/catalog.ex` | the own-catalog + island mutants for one hosted condition |
| `host/join_on.ex` | home of join `on:` hostability (a join's sole, top-level, non-`assoc` on-expression) |
| `host/target.ex` | the `dynamic`-wrap / `^`-pin / splice transforms core consumes |
| `fragment.ex` | the SQL-semantics catalog for conditions (public family table); home of the SQL side of the ownership rule, the `is_nil` interior rule (the walk never enters it; only the coalesce drop is read beneath it), and the structural-position registry |
| `subquery.ex` | recurses the catalogs into an inline subquery; home of the wrapper observation modes and what is deliberately out of reach |
| `island.ex` | the interpolation-island seam; home of the sub-contract and the pin-side keyword-key rule |
| `walk.ex` | the one structural walk under every catalog; home of the author-macro rule and node-level attribution |
| `expression_walk.ex` | the value-expression rules over `walk.ex` (the `over/2` `order_by:` refinement) |
| `value_catalog.ex` | capability → catalog dispatch for an in-place clause value, and the ordering-position rule (`position/1`) |
| `ordering.ex` | direction / nulls-placement flips and the implicit-`asc` re-tag; home of the engine-default NULL placement table and of why `order_by` is never dropped |
| `aggregate.ex` / `scalar.ex` | shared per-node catalogs (the aggregate ladder; arithmetic swaps + the coalesce drop); `aggregate.ex` is home of the `count` exclusion |
| `combination.ex` | the set-operation swap table (`union` deliberately unswapped) |
| `bound.ex` | the `:bound` ±1 bump; home of pin-only hosting and the `literal?/1` = `bumps/1` agreement |
| `dynamic.ex` | free-standing `dynamic/1,2`; home of its whole-call in-place delivery |
| `query.ex` | whole-`from` rewrites; home of the JoinType narrowing rationale |
| `clause.ex` | standalone/pipe cousins of `query.ex` |
| `clause_drop.ex` / `changeset.ex` | stage drops (a query clause / a changeset validator or hook) over `stage_drop.ex` |
| `stage_drop.ex` | home of pipe-aware stage-drop delivery |
| `binding_reorder.ex` | home of the in-place binding-reorder rule |
| `repo_aggregate.ex` / `repo_write.ex` / `query_terminal.ex` | bucket-1 families; `repo_write.ex` is home of the `on_conflict` swap rules and of the persistence rewrite's error-path parity rule (the mutant restates the write's Repo and action, so it may differ only on a *successful* write) |
| `repo_call.ex` | the resolve-on-the-configured-`repo:` preamble |
| `config.ex` | option parsing into `%Config{}`; home of parse-once / `context.config` |
| `equivalence.ex` | home of the equivalence-sensitive set, each family's note, and the `finalize/2` funnel (context-free, over a `%Config{}`) |
| `vocabulary.ex` | the `variant_labels/0` callback; home of vocabulary canonicalisation |
| `ast.ex` | typed literal readers + list unwrap/rewrap; home of "emit through core's `Mutare.AST`, `Elixir.`-prefixed" |
| `ast/query_call.ex` / `ast/from_call.ex` / `ast/binding_list.ex` / `ast/keyword_list.ex` | normalized values that preserve the written form; `FromCall` is home of the empty-clause-list collapse |
| `binding.ex` | the primitive binding-entry vocabulary |

### Families and configuration

- Every mutation is tagged with an SQL **family**; `Mutare.Ecto.Config` (via
  `use Mutare.Mutator.Families`) holds the canonical `:all` list and the opt-in set.
- The user-facing grammar — `families:` (`:default`/`:all`/list/`{base, except: […]}`),
  `dialects:`, `repo:`, `as:` (multi-repo and per-family report naming) — is documented once, in
  `Mutare.Ecto`'s moduledoc (and the README).
- The equivalence-sensitive families, each family's `… kill may require …` note, and the
  `finalize/2` funnel that applies the `families:` filter and the note on both delivery paths:
  `Mutare.Ecto.Equivalence`.
- Per-site suppression is `# mutare:ignore[ecto:<family or finer label>]`; the vocabulary is
  assembled by `Mutare.Ecto.variants/0` from every `Mutare.Ecto.Vocabulary` implementer.

## Conventions and gotchas

Each is the conclusion; the canonical statement is in the named module.

- **Never reuse a core mutator inside a query fragment — and never point the SQL catalog at
  Elixir.** The SQL structure/operators/literals are the plugin's (`Mutare.Ecto.Fragment`); a
  `^` pin's interior is ordinary Elixir, sub-contracted to core over the run's full spec set and
  relayed with `producer:` (`Mutare.Ecto.Island`).
- **A nested author macro may invent its own argument syntax — descend only into `:expression`**
  (or a non-macro node); every other routing is left raw. `Mutare.Ecto.Walk`.
- **Binding-reorder is always in-place, never a body rewrite.** `Mutare.Ecto.BindingReorder`
  (a `from` source list reorders at the whole-`from` level, `Mutare.Ecto.Query`).
- **Stay inside the single build.** Any in-query mutation must be `^`-pinned behind the selector —
  a bare `case` in a query position poisons compilation. New query-position families go through
  the host (`Mutare.Ecto.Host`); the pin-only bound bump (`Mutare.Ecto.Bound`) is the precedent.
- **Sourceror wraps literals** as `{:__block__, meta, [value]}`: read through `Mutare.Ecto.AST`'s
  readers, emit through core's `Mutare.AST` constructors, never hand-build a block. Emitted module
  references are `Elixir.`-prefixed (alias-proof). `Mutare.Ecto.AST`.
- **Match calls through `Mutare.Calls`**, never `Mutare.Transform.Calls` (core-internal):
  `resolved_call_to/3` for single-module matching, `resolved_call/1` + `module_key/1` for
  table-driven dispatch — never a hand-built `[:Ecto, :Query]` key.
- **Producers stay pure.** They return `%Mutare.Ecto.Tag{}`s; the `families:` filter and the
  equivalence note are applied once, by core, in `finalize/2` on both delivery paths
  (`Mutare.Ecto.Equivalence`). A `producer:`-relayed island mutant bypasses it.
- **A new macro kind must take a real branch in every dispatch** — `macro_kind_parity_test.exs`
  fails until it does. `Mutare.Ecto.Surface.macro_kinds/0`.
- **One home per rule in the docs.** Mechanics and family rationale → the owning module's doc;
  history ("used to be …") → `NOTES.md` "Design history"; cross-module gotchas → here, as a
  pointer. Layering per `../mutare/.claude/skills/editing-docs/SKILL.md`. Public moduledocs are
  hexdocs; only `mix docs` validates their autolinks (a public doc referencing a hidden module
  needs the referencing module in `mix.exs`'s skip-list).

## Tests

- Unit tests (most files) drive `Mutare.transform_string/2` over fixture source strings and assert
  the recorded `Site`s (logical diffs + family names) and that the rendered metamutant compiles.
  Helpers: `Mutare.Ecto.TestSupport` (`diffs`, `ecto_diffs`, `assert_compiles`, `metamutant`).
  Test mutators **default to the Ecto plugin alone** (`{Mutare.Ecto, repo: MyApp.Repo}`), so
  recorded mutations are exactly the plugin's — pass `mutators: [:all, …]` to include core's.
- The semantic suite (`Mutare.Ecto.SemanticCases`, instantiated per engine — see
  [the engines section](#the-semantic-suites-engines-sqlite-always-postgres-opt-in)) proves a
  recorded mutant is **live**: it compiles the metamutant, flips `:persistent_term`'s
  `:mutare_active` to a chosen mutant id, runs the query against the seeded `@repo`, and asserts
  the result set changed the way the mutation predicts. The standard shape is core's
  `observe_mutant/3` flip-and-compare (via the harness's `observe/4` — the mutant resolved from a
  Site's logical diff, the baseline run first and pinned); `site_id/2`/`site_by/3` +
  `under/3`/`activate/2` remain for multi-mutant builds, the token-absence drops, and the write
  path.
- The fixtures and assertions are engine-agnostic: every DB helper takes the Repo module first,
  `H.full_join_supported?/1` runtime-gates the one FULL-JOIN fixture, and aggregate values route
  through `to_number/1` (Postgres hands back `Decimal` where SQLite gives a float). Fixtures:
  `test/support/myapp.ex` (schemas + both Repos) and `test/support/seed.ex` (adapter-typed DDL;
  boundary/NULL rows chosen so each family is distinguishable).
- Because `Code.compile_string` is global, Mutare's public test helpers compile fixtures inside
  uniquely named wrapper modules so async tests defining the same module name do not race.
