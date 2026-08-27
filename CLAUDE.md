# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`mutare_ecto` is a mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), implemented as a
custom [Mutare](../mutare) mutator. It mutates the Ecto surface an app writes — `Repo` calls,
changeset pipelines, and the `from`/query DSL.

Its load-bearing design rule: **reuse none of Mutare's built-in mutation logic inside a query
fragment** — core reasons in Elixir's semantics, not SQL's (three-valued boolean logic, NULL
handling, boundary behaviour), and would silently manufacture false negatives — while reusing
**all** of Mutare's plumbing (identity resolution, selector/coverage/poison/Site machinery, and
the delivery host). The full statement of that rule, and where it cuts, is the first entry of
[Conventions and gotchas](#conventions-and-gotchas).

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
Features that have gone that route after such a decision: the selector host, `:routing`/`:hosted` macro routing, `{:keyword, …}` per-pair
routing, `:interpolated` in-place delivery, the `Site` `note` channel, the plugin-config toolkit
(`c:Mutare.Mutator.init/1` + `use Mutare.Mutator.Families`), `:mutators` threaded into the
whole-call `mutate/2` offer of a registered macro (the free-standing-`dynamic` sub-contract seam;
later widened to the **full** spec set — with a nested host's targets *lowered* to whole-call
rebuilds in collect — so a pin interior is analyzed like top-level Elixir: an inner
`dynamic(...)` reaches its owner and an inner `from`'s hosted conditions surface as rebuilds),
the `c:Mutare.Mutator.finalize/2` enrichment seam core runs on both delivery paths, the
`c:Mutare.Mutator.required_modules/0` environment guard, the shared `:structural`
argument-mark label (`Mutare.Mutator.structural_label/0`/`pinned?/1` — declined by every
`:skip_arguments`-honouring value family; the plugin declares it on `apply_action`/`apply_action!`'s
action atom via `argument_marks/1`), and the published off-by-one/zero table
`Mutare.AST.numeric_alternatives/3` (the built-in numeric families' own candidates, drop rule,
and label-merging collapse — consumed by `fragment.ex`'s integer/float arms so the plugin's
`# mutare:ignore[ecto:zero]` vocabulary can't drift from core's `[integer:zero]`).

Core's public test surface for plugins is `Mutare.Test`, wrapped here by
`Mutare.Ecto.TestSupport` (threads the plugin's default mutators, forwards every other option).
The suites also use core's `observe_mutant/3` flip-and-compare and the shipped
`Mutare.Test.Fixtures.RoutingExtension` for foreign-routing composition.

**Deployment requirement:** Mutare must run **as a dependency of the app under test** so Ecto and
the app's schemas are on the BEAM code path. This is what lets `use`-expansion expand
`use Ecto.Schema` (so `schema do … end` resolves and the `:skip` routing fires) and lets the host
build valid `dynamic` calls. External-source operation is unsupported and guarded declaratively:
`required_modules/0` (`c:Mutare.Mutator.required_modules/0`) declares the Ecto surface
(`Ecto.Schema`/`Ecto.Query`), and core checks it once at startup — a missing module aborts with a
`Mutare.EnvironmentError` before any source is read. Beyond that guard, unresolved target-app
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

`Mutare.Ecto` (`lib/mutare/ecto.ex`) is a thin `Mutare.Mutator` front that **dispatches by the
node it sees** to a family of sub-mutators. Beyond `Mutare.Mutator` it implements core's two
adapter behaviours — `Mutare.MacroRouting` (DSL routing) and `Mutare.Mutator.MacroHost` (selector
hosting):

- `macro_routes/0` (`Mutare.MacroRouting`) — registers the compile-time DSL routing so core never
  splices a runtime selector into a query expression (which would poison the single build).
  `schema`/`embedded_schema` → `:skip`; query-building macros (`from`, `where`, `order_by`,
  `limit`, `select`, `join`, …) → `:routing`. The classifier hosts SQL conditions, keeps DSL data
  raw, and marks a directly passed query argument `:expression` so upstream query mutations remain
  reachable through a stage.
- `route_arguments/2` (`Mutare.MacroRouting`, the `:routing` classifier — receives a resolved
  `Mutare.MacroRouting.Call`, returns `Mutare.MacroRouting.ArgumentRoutes`) and `host/2`
  (`Mutare.Mutator.MacroHost` — returns `Mutare.Mutator.MacroHost.Target`s) — both delegate to
  `Mutare.Ecto.Host` (the selector host). `hosted_macros/0` subscribes the host to exactly the
  macros the classifier can route `:hosted` (`from`, the condition macros, `join`, and the bound
  clause macros `limit`/`offset` — `Surface.hosted_macro_names/0`).
- `init/1` (`Mutare.Mutator`) — parses the instance's options once, at spec resolution, via
  `Config.parse!/1`; a typo'd option raises at startup, and core delivers the parsed `%Config{}`
  to every context-aware callback as `context.config`.
- `mutate/2` — asks `Mutare.Ecto.Dispatcher` to classify the node and invoke only relevant
  sub-mutators, then returns the resulting `%Mutare.Ecto.Tag{}`s as tagged `Mutation`s
  (`Tag.to_mutation/1` — pure production, no filtering; a `Dynamic`-relayed producer-set `Mutation`
  passes through as-is). Everything runs through `mutate/2` because all mutations read
  `context.config`.
- `finalize/2` (`Mutare.Mutator`, delegated to `Equivalence.finalize/2`) — the one
  tag → filter → enrich funnel: reads the mutation's leading variant label back as its SQL family,
  drops a disabled family (`families:`), attaches the equivalence note. Core applies it to every
  produced mutation on **both** delivery paths (a `mutate/2` return and a host target's
  `:mutants`), so no delivery site can forget the filter or the note. A relayed island mutant
  (explicit `producer:`) bypasses it — the producer's own funnel (a core family's, or this
  plugin's for an interior Ecto mutant) already ran at generation, inside the sub-contract seam.

### The three delivery buckets (the spine of the design)

The surface divides by **how a mutation is delivered**, not by what it mutates:

**1. Plain calls** — `Repo.aggregate`, changeset validators, `Repo.insert`, `first`/`last`. Not
DSL; resolved through `Mutare.Calls` (so direct/aliased/imported forms all match) and delivered by
Mutare's ordinary in-place selector. Needs no new core machinery. Modules: `RepoAggregate`,
`RepoWrite`, `Changeset`, `QueryTerminal`, plus the whole-`from` rewrites in `Query`, the
standalone/pipe rewrites in `Clause`, and the free-standing `dynamic/1,2` rewrites in `Dynamic` —
a `dynamic` call sits in ordinary expression position (its value is a runtime `DynamicExpr`), so
its in-fragment mutants (the same `Fragment` catalog the host uses, scalar/aggregate per-node
catalogs folded in) are whole-call rewrites, not woven — each *reported* at the mutated
expression, the walk's anchor. That includes its **island sub-contract**: core threads `context.mutators`
into the whole-call offer of a registered macro, so `Dynamic` relays each pin interior's mutants
through the same seam as the host (`Island.subcontracted/3`), delivered as rebuilt calls.

**2. Skipped** — `schema`/`embedded_schema` bodies. A mutated field name/type is a broken schema,
not a mutant.

**3. Hosted DSL** (the heart) — in-fragment `where`/`having` mutations, delivered woven behind a
selector because a query clause can't host a runtime `case`:

- **The weave.** Operator swaps (and the `sum`↔`avg`/`min`↔`max` aggregate swap inside a
  `having: sum(p.x) > n`) are woven behind Ecto's `^` + `dynamic` injection (`Mutare.Ecto.Host` +
  the SQL catalog in `Mutare.Ecto.Fragment`, which applies the shared `Scalar`/`Aggregate`
  per-node catalogs as it walks — one walk per condition).
  Exactly one branch bakes into the compiled query per run, selected by
  `:persistent_term.get(:mutare_active, 0)`.
- **Bound bumps.** The `:bound` ±1 bump of a literal `limit`/`offset` is hosted too, as a
  **pin-only** target (`limit: ^(case …)` — no `dynamic/2` wrap, no bindings): a bound is an
  integer parameter, so the pinned selector is plain Ecto interpolation with a behaviorally
  identical baseline, and the bump never duplicates the whole query the way a whole-`from` rewrite
  would. `Bound` is the bump catalog and the literal guard `Routing` consumes. (The bound *drop*
  stays a whole-`from`/stage rewrite in `Query`/`ClauseDrop`.)
- **Interpolation islands.** A hosted condition's `^expr` interiors — ordinary Elixir evaluated at
  runtime — are **sub-contracted to generation over the run's full spec set**, i.e. analyzed
  exactly like top-level Elixir: `Fragment.islands/1` finds each pin under the catalog's own
  descent rules, `Island` runs `Mutare.Analyze.expression_mutations/3` over
  `context.mutators` (the run's enabled specs — this plugin included through its ordinary
  `mutate/2` surface, so an inline `dynamic(...)` literal inside the pin mutates once, under SQL
  semantics, by `Dynamic`, and an inner `from`'s hosted `where:` swaps come back **lowered** —
  each hosted target mutant as the inner call rebuilt with the mutated condition spliced
  `^dynamic`-pinned, the woven selector degenerated to its selected branch — so hosted delivery
  never nests while hosted semantics are never lost) and relays each rebuild as a `Mutation`
  with `producer:` set — so the Site belongs
  to the producing family while delivery rides the host's weave. One positional rule guards the
  seam: a **keyword key in a condition position names a column**, so a relayed mutant that changes
  the interior's keyword-key set is dropped (`subcontracted/3` — the pin-side application of the
  same rule the shorthand routing applies to written `where(q, col: v)` pairs; a bare/computed
  keyword list has no call shape for dispatch to recognize, so only this seam can apply it).
- **Subqueries.** A hosted condition can contain a subquery (`where: exists(from …)`,
  `p.x >= all(from …)`, `p.x > subquery(from …)`, `p.id in subquery(from …)`):
  `Mutare.Ecto.Subquery` recurses the plugin's own catalogs into the inline `from`'s interior —
  its `where`/`having` swaps + pins, filter-drops, and join-type flips under **every** wrapper,
  and its `select` projection under a **value-wrapper only** (`all`/`any`/`subquery`/`in`;
  suppressed under `exists`, whose select SQL never evaluates — the same
  unconditional-equivalence class as an `is_nil` interior). Each inner mutant is the whole outer
  condition rebuilt, so it rides the identical weave with no new machinery.
- **Out of reach, deliberately.** Inner `order_by`/`limit`/`distinct` (inert or flaky through the
  wrappers we host) and a *from-source* subquery (`from s in subquery(…)`, routed `:skip`) — the
  latter earns its interior mutants by being built as a standalone query first.

### Module map (`lib/mutare/ecto/`)

| Module | Role |
|---|---|
| `ecto.ex` | `Mutare.Mutator` + `Mutare.MacroRouting` + `Mutare.Mutator.MacroHost` callbacks: parses config once via `init/1`, delegates node classification; `finalize/2` filters by `families:` and applies the note; `argument_marks/1` pins `apply_action`/`apply_action!`'s action atom against core's value families (the shared `:structural` mark — metadata-only, so mutating it is noise) |
| `dispatcher.ex` | Classifies each node once and invokes only the sub-mutators relevant to that query macro, Ecto call, or configured Repo call |
| `surface.ex` | Single descriptor table for every owned query macro and `from` key: routing kind, standalone mutation capabilities, stage/whole-`from` drop families, and hosted/binding/join capabilities |
| `sub_mutator.ex` | The uniform `mutations(node, context)` behaviour implemented by each mutation producer |
| `tag.ex` | `%Mutare.Ecto.Tag{family, node, label, attribution}` — the **one** shape every producer and shared catalog emits (previously three tuple arities), plus `map_node/2`, the "rebuild the surrounding form around each mutant" step; `to_mutation/1` turns it into the delivered `Mutation` (a producer-set relayed `Mutation` passes through untouched) |
| `host.ex` | Selector-host **coordinator** (bucket 3): turns a hosted call into `Target`s — condition weaves plus the pin-only bound-bump targets — delegating to the `host/*` parts below |
| `host/routing.ex` | `route_arguments/2` — the per-argument routing classifier (`:hosted`/`:expression`/`:skip`/`:interpolated`/`{:keyword,…}`), over `treatments/2` |
| `host/condition.ex` | `locate/1` — the host-owned condition argument of a `where`/`having` (and the free-standing `dynamic`, which shares their shape) as a `%Condition{node, index, bindings}`: the binding-form (one slot past the written list) and binding-less (trailing argument, `bindings: nil`) shapes. Pure argument-shape parsing, consumed by `host.ex`, `host/routing.ex`, and `dynamic.ex`; rendering the declarations is `host/bindings.ex`'s job |
| `host/bindings.ex` | Interprets Ecto binding declarations and renders the binding list re-declared by a woven `dynamic/2` (`declarations/1` renders a located condition's written list, or `[]` for the binding-less form) |
| `host/catalog.ex` | The tagged logical mutants for one hosted condition: the plugin's own catalog (`own_catalog/2` — `Fragment`, the scalar/aggregate catalogs folded in; the raw tags `dynamic.ex` shares; filtered/noted later by `finalize/2`) plus the island mutants relayed through `island.ex` (`mutants/3`) |
| `host/join_on.ex` | Which join `on:` conditions are safe to host: only a join's **sole, top-level** on-expression (not a multi-`on:` or `assoc` join, whose conditions Ecto folds into one `and` where a `^dynamic` operand is illegal) |
| `host/target.ex` | The `dynamic`-wrap + `^`-pin + splice transforms consumed by core, plus the pin-only bound targets (no wrap — each branch is a bare integer) |
| `fragment.ex` | The **SQL-semantics catalog** for `where`/`having` conditions (Comparison, Connective, NullPredicate, Membership, Arithmetic, Coalesce, Temporal, the literal arms IntegerLiteral/FloatLiteral/StringLiteral/AtomLiteral/BooleanLiteral): a per-node `local/3` read over `walk.ex`'s positions under its own `children/2` descent rule (the `is_nil`/`in`/`exists` units and their `not` forms; the `{parent_form, arity, index}` position the literal arms consult) — stops at every `^` pin, whose interiors `islands/1` (the second reader of the same positions) collects for the host's core sub-contract; recognizes an `exists`/`all`/`any`/`subquery`/`in` subquery wrapper and hands its inline `from` interior to `subquery.ex` |
| `subquery.ex` | Recurses the plugin's own catalogs into a subquery's **interior** (see bucket 3 above for what's reachable under which wrapper). Each mutant is the whole inner `from` rebuilt, which `fragment.ex` wraps back into the condition and delivers through the same `Fragment.mutants`/`islands` seam the host and `dynamic.ex` already consume |
| `island.ex` | The interpolation-island **seam**, shared by both condition owners (the host via `host/catalog.ex`, the free-standing `dynamic` via `dynamic.ex`): `subcontracted/3` runs each `^` pin interior (`Fragment.islands/1`) through `Mutare.Analyze.expression_mutations/3` over `context.mutators` — the run's full spec set — and relays every rebuild as a `producer:`-attributed `Mutation`, parameterized by delivery (`deliver`). Its keyword-key-set guard is the pin-side application of the "keys name columns" rule |
| `ast/query_call.ex` / `ast/binding_list.ex` / `ast/keyword_list.ex` | Normalized query-call, binding-list, and keyword/clause-list values; preserve written form while centralizing validation and reconstruction |
| `binding.ex` | Primitive binding-entry vocabulary (`variable?`/`ellipsis?`/`entry?`) used by the normalized binding list |
| `binding_reorder.ex` | Positional binding-reorder (`[a, b]`→`[b, a]`) for **every** standalone/pipe binding-list macro — `where`/`having` included — delivered **in-place** by swapping the written list, never the condition body. A `from` binding-list *source* (`[a, b] in q`) reorders at the whole-`from` level (`query.ex`) instead |
| `query.ex` | Whole-`from` rewrites (clause drop, order flip, bound **drop**, join-type, `select`/`order_by` aggregate, source binding-reorder for a `[a, b] in q` source) — the bound *bump* is hosted instead |
| `clause.ex` | Standalone/pipe cousins of `query.ex` (`order_by`/`select`/set-operation macros; the `limit`/`offset` bump is hosted) |
| `clause_drop.ex` | Drop a standalone/pipe clause stage (`q \|> where(…)` → `q`), via `stage_drop.ex` |
| `ordering.ex` / `aggregate.ex` / `scalar.ex` | Shared self-tagging (`tag.ex`) catalogs used by `query.ex`, `clause.ex`, and the condition host. `aggregate.ex` (`sum`↔`avg`/`min`↔`max`) is applied per node by `fragment.ex` in a condition (so never under `is_nil`, where it preserves NULL-ness) and walked over `select`/`order_by` values. `scalar.ex` owns the Arithmetic swaps and the Coalesce fallback drop, applied per node by `fragment.ex` in hosted conditions and walked over `select`/`order_by` values; an **ordering-position** drop (an `order_by` value, or an `over/2` window's `order_by:` option) is labelled `coalesce_in_ordering` and carries its own note — dropping a sort key's fallback re-sorts only the NULL rows to the engine's *default* NULL placement, so its equivalence turns on the fallback agreeing with that default. `ordering.ex` flips a sort direction (`:asc`↔`:desc`) / nulls placement, **and** re-tags the implicit `asc` of a bare ordering term (`:name`, `u.name`) to `desc` — the reliable replacement for the removed `order_by` clause-drop (dropping an `ORDER BY` left an SQL-unspecified row order, so its survival tracked engine nondeterminism, not the tests); its module doc also holds the engine-default table (Postgres sorts NULL as larger than every value, SQLite/MySQL as smaller; MySQL can't express the qualifier) behind the rule that a bare direction is never nulls-qualified |
| `walk.ex` | The **one** structural walk under every catalog. `Walk.positions/3` yields each admitted node as `{node, ctx, rebuild}` (`rebuild` reconstructs the walked root around a replacement), `Walk.mutants/4` reads a per-node `local` catalog over those positions and **anchors** every mutant at its node (`Mutation.at/2`), so in-place deliveries (`query.ex`/`clause.ex`/`dynamic.ex`) report Sites at the mutated expression's own line — two identical `coalesce(a, b)`s in one `select`, or two comparisons in one `dynamic`, become individually `# mutare:ignore`-able (hosted relays discard the stamp structurally); `Walk.structural/3` is the default descent — a call's arguments **only** where the author-macro rule admits them (a non-macro node, or an argument the macro routed `:expression` per `Mutare.Calls.macro_treatment/1`), a list's elements, a 2-tuple's sides; a `^` pin is a leaf. A catalog's own `children/2` rule wraps it to claim a unit (`fragment.ex`'s `not is_nil(x)`: one position, the inner predicate never its own), refuse a shape (`fragment.ex` declines 2-tuples), or refine a child's ctx (`expression_walk.ex`'s `over/2` `order_by:` option). `fragment.ex`'s `mutants` and `islands` are two readers of the same positions, so they agree by construction (`fragment_descent_test.exs` pins the policy itself) |
| `expression_walk.ex` | The value-expression rules over `walk.ex` for the expression catalogs (`aggregate.ex`, `scalar.ex`): threads the ordering `position` to the catalogs and refines it itself inside an `over/2` window's `order_by:` option |
| `combination.ex` | Shared set-operation swap catalog (`intersect`↔`except`, `intersect_all`↔`except_all`; `union` deliberately unswapped) used by `query.ex` (clause-key swap) and `clause.ex` (macro-name swap) |
| `bound.ex` | The `:bound` family's ±1 **bump** arm for a literal `limit`/`offset` value: `bumps/1` (the tagged mutants — `n+1` always, `n-1` only while non-negative) and `literal?/1`, defined as `bumps/1` non-emptiness, so the routing classifier and the host agree by definition on what is a literal bound. The bump is delivered pin-only by `host.ex`; the family's *drop* arm lives in `query.ex`/`clause_drop.ex` |
| `dynamic.ex` | In-fragment mutations of a **free-standing** `dynamic/1,2` (`d = dynamic([p], p.x > ^v)`): the shared `Fragment` catalog over its condition (scalar/aggregate folded in) **plus** the island sub-contract per `^` pin (via `Island.subcontracted/3` over `context.mutators`), each mutant the whole call rebuilt and delivered in place (the `dynamic` registers `:skip` so core keeps its DSL args raw, but core still offers the whole call to `mutate/2` — with the run's specs threaded in) |
| `repo_aggregate.ex` / `repo_write.ex` / `query_terminal.ex` | Bucket-1 Repo/query-function families |
| `repo_call.ex` | Shared "resolve a call on the configured `repo:`" preamble for `repo_aggregate.ex`/`repo_write.ex` |
| `stage_drop.ex` | Shared pipe-aware stage-drop delivery for `clause_drop.ex` and `changeset.ex` |
| `changeset.ex` | Changeset pipeline drops (`:validation_drop`, `:hook_drop`) |
| `config.ex` | `families:`/`dialects:`/`repo:` parsing + validation (`parse!/1`, run once by `init/1`; the family catalog via core's `use Mutare.Mutator.Families`) into the `%Config{}` every production accessor takes — production never holds raw options; a unit test builds a struct through `parse!/1` |
| `equivalence.ex` | The equivalence-sensitive family set and each family's report note (`note/2`, refined by the finer label), plus the `finalize/2` funnel body — the `families:` filter and the note, applied once by core on both delivery paths |
| `vocabulary.ex` | The `variant_labels/0` `@callback` each label-tagging producer (`fragment.ex`, `scalar.ex`, `aggregate.ex`, `ordering.ex`, `query.ex`, `combination.ex`) implements, returning its finer `# mutare:ignore` labels **raw** (derived from its own swap/flip table); `Mutare.Ecto.variants/0` iterates the implementers and dedupes/sorts the union once — the single place the vocabulary is canonicalised |
| `ast.ex` | Small Sourceror AST helpers the plugin genuinely owns: typed literal *readers* (`atom_value`/`int_value`), the list unwrap/rewrap pair (`unwrap_list`/`rewrap_list`, over core's `unwrap_literal`) — everything *emitted* comes from core's `Mutare.AST` constructors |

### Families and configuration

Every mutation is tagged with an SQL **family**; `config.ex` holds the canonical `:all` list.

- `families:` selects the catalog (an unknown name fails loudly). Accepted values:
  - `:default` (the unset default) — every family **except** the opt-in
    `:string_literal`/`:atom_literal`/`:boolean_literal` arms, which are off for safety: a
    string/atom value space is large and a direct boolean literal rarely idiomatic, making their
    mutants the noisiest.
  - `:all` — every family.
  - An explicit list.
  - `{:default | :all, except: […]}` — base-minus-exclusions, the easy way to drop a default-on
    arm.
  - Even when the opt-in arms are enabled, `fragment.ex`'s structural-position guard still
    suppresses a literal at a known DSL form's structural argument.
- `dialects:` gates non-portable mutations: `like`↔`ilike` under `:postgres`; `LEFT`↔`RIGHT` join
  under `:postgres`/`:mysql` (SQLite lacks `RIGHT JOIN`).
- Multi-repo and per-family report naming fall out of Mutare's `:as` convention (list the plugin
  twice).
- The **equivalence-sensitive** families (`:comparison`, `:connective`, `:null_predicate`,
  `:arithmetic`, `:coalesce`, `:temporal`, `:ordering_nulls`, `:join_type`) carry a report `note` —
  a survivor reads `… kill may require …` — because their unkillability can be honest signal (a
  data gap, not a test gap). Each family's note names the **specific** data a kill needs, because
  the reasons differ: a boundary row (`:comparison` ordering swaps), a non-NULL row (`:comparison`
  `==`/`!=`), a disagreeing row under three-valued logic (`:connective`), NULL rows in the column
  (`:null_predicate`, `:ordering_nulls`) or in the coalesced expression (`:coalesce` — whose
  ordering-position sub-case, `coalesce_in_ordering`, additionally needs the fallback to disagree
  with the engine's default NULL placement), or an
  operand off the operation's identity (`:arithmetic` — 0 for `+`/`-`, ±1 for `*`/`/`).
  `Equivalence.note/2` resolves the note (refining `:comparison` and `:arithmetic` by the
  swapped operator, and `:coalesce` by the position label).
- The note rides onto the `Site` via the `finalize/2` funnel (see Architecture), which core runs
  on **both** delivery paths just before recording — so the in-fragment families surface it
  through the host and `:ordering_nulls`/`:join_type` through their `mutate/2` rewrites, and no
  delivery site can forget it. Producers stay pure: they return `%Mutare.Ecto.Tag{}`s wrapped by
  `Tag.to_mutation/1` into `Mutation`s carrying `variant: [family | finer]`.

## Conventions and gotchas

- **Never reuse a core mutator inside a query fragment — and never point the SQL catalog at
  Elixir.** This is the one rule the whole design exists to enforce, and it cuts both ways along
  the `^` pin boundary. The SQL **structure/operators** are the plugin's, owned end to end in
  `fragment.ex` (core would reason in Elixir's semantics). A pin's **interior** is ordinary
  Elixir evaluated at runtime — never the SQL catalog's (an SQL-rationale
  `^(min * 2)` → `^(min / 2)` mutates the parameter's Elixir value/type): the catalogs stop at
  every pin, and each island is **sub-contracted** to generation over the run's **full** spec
  set (`Mutare.Analyze.expression_mutations/3` over `context.mutators`), i.e. analyzed exactly
  like top-level Elixir-that-includes-Ecto — core's families own the Elixir, and any Ecto
  surface *inside* the interior is the plugin's own again (an inline `dynamic(...)` literal is
  offered whole-call to `Dynamic` and mutates once, under SQL semantics; an inner `from`'s
  hosted conditions are **lowered** by collect to whole-call rebuilds — hosting is a delivery
  optimization, not a semantic category, so where the weave is unavailable the same mutant
  ships as the rebuilt call; ownership recurses one pin level at a time). Each rebuild is
  relayed with `producer:` so the Site and ignore
  vocabulary belong to the producing family — delivery stays the relayer's: the host's weave for
  a hosted `where`/`having`, the whole-call in-place rewrite for a free-standing `dynamic`. A
  `^value` referencing an upstream binding is mutated by core where it is bound, as always.
- **A nested author macro may invent its own argument syntax — only descend into `:expression`.** A
  user can define a macro and use it inside a `where`/`having` condition; its arguments are valid
  Elixir *tokens* but their meaning is the macro's own (it can make up a DSL, exactly as Ecto does).
  Mutare mutates **source**, not expansions, so there's nothing "downstream" to protect — the thing
  `:skip` protects is the **argument source**. There is one structural walk (`walk.ex`,
  `Mutare.Ecto.Walk`), and its default descent (`Walk.structural/3`) reads each nested call's
  per-argument routing via `Mutare.Calls.macro_treatment/1` (stamped by the resolve pre-pass) and
  descends into an argument **only** when it's plainly standard syntax — a non-macro node, or an
  argument the macro routed `:expression`. Every other routing (`:skip`, `:pattern`, `:hosted`, …)
  is left raw. Every catalog (`fragment.ex`'s `mutants`/`islands`, `expression_walk.ex`) is a
  per-node reader over that walk's positions and never descends on its own — a catalog's
  `children/2` rule can only narrow what the walk admits.
- **Binding-reorder is always in-place, never a body rewrite.** Transposing `[a, b]` → `[b, a]`
  swaps the *written binding list* — `binding_reorder.ex` for the standalone/pipe macros
  (`where`/`having` included), `query.ex` for a `from` `[a, b] in q` source. It never rewrites the
  condition body, so it is safe across an opaque author macro without having to understand the
  macro's arguments. Usage is deliberately irrelevant: unused declarations still produce swaps,
  while `_`-prefixed and named bindings never participate. (A scalar `from` source and synthesized
  join bindings are not author-written lists, so they never reorder.)
- **Stay inside the single build.** Any in-query mutation must be delivered `^`-pinned behind the
  selector — a bare `case` in a query position poisons compilation. New query-position families go
  through the host, not the in-place selector.
- **Sourceror wraps literals** as `{:__block__, meta, [value]}`. Read values through the
  `AST.*_value/1` helpers, and emit fresh nodes through **core's `Mutare.AST` constructors**
  (`literal/1`, `keyword_key/1`, `clean_var/1`, …) — they own Sourceror's emission invariants
  (clean/derived meta so the renderer never re-emits the old text, numeric `:token`s, string
  delimiters, the negative-number shape). Never hand-build a `{:__block__, meta, [value]}`.
- **Match calls through `Mutare.Calls`**, never `Mutare.Transform.Calls` (core-internal):
  `resolved_call_to/3` with the real module atom for single-module matching,
  `resolved_call/1` + `module_key/1` for table-driven dispatch across modules — never a
  hand-built `[:Ecto, :Query]` key.
- **Emitted module references are `Elixir.`-prefixed** (`Elixir.Ecto.Changeset.apply_action`,
  `Function.identity`) via `Mutare.AST.absolute_alias/1`/`absolute_call/3`. The metamutant
  recompiles in the author's aliasing scope, where a bare `Ecto.Changeset` could be retargeted by
  an `alias`; only the absolute name is poison-proof.

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
