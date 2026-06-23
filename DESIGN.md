# Mutare.Ecto — a mutation-testing plugin for Ecto

**Codename:** mutare_ecto · **Status:** design draft · **Depends on:** Mutare ≥ (the release shipping the delivery-host + `:hosted` routing extensions), Ecto ≥ 3.x

Mutare mutates the Elixir source the author wrote. Ecto code *is* Elixir source — but its highest-value parts are a **compile-time DSL that evaluates under SQL semantics, not Elixir's**. A `where` clause is not an Elixir boolean expression; it is a fragment of SQL whose three-valued logic, `NULL` propagation, and operator set differ from the host language it is embedded in. `mutare_ecto` is the external plugin that teaches Mutare to mutate the Ecto surface — Repo calls, changeset pipelines, and above all the `from`/query DSL — **without ever pretending SQL is Elixir.**

**The thesis, in one line.** `mutare_ecto` is a *delivery adapter* plus a *native SQL-semantics mutator catalog*. It reuses **none** of Mutare's built-in mutation logic inside the query DSL — the semantics don't match, and the mismatch silently manufactures false negatives (see *The semantic boundary*, below) — but it reuses **all** of Mutare's plumbing: lexical identity resolution, the selector / coverage / poison / Site machinery, and (newly) a delivery host for weaving a mutation into a DSL position via `^` + `dynamic`.

**Assumed core extensions.** This design assumes two Mutare-core extensions, specified in Mutare's `NOTES.md` under *"Mutating inside a foreign-semantics DSL — the Ecto `from` host"*:

- **(#1) A mutator-supplied selector host.** Per mutation target, the plugin hands Mutare `{logical original, logical mutants}` plus two pure transforms — `wrap` (each selector branch → `dynamic([bindings], _)`, or identity) and `splice`/`pin?` (where the woven node goes, `^`-pinned). Mutare still assigns the ids, builds the `case` from its own selector subject, records the Site from the logical pair, and emits the coverage catch-all.
- **(#2) A `:hosted` macro-argument treatment + shape-aware routing.** A fifth argument treatment meaning "don't splice a bare selector here — route this position's mutations through the host," plus a per-call `macro_routing/1` classifier consulted during lexical resolution (so the keyword and binding forms of `where` route differently).

Everything else the plugin needs already exists in Mutare today: the known-macro registry (`macros/0`), `use`-expansion (so `use Ecto.Schema` / `use MyAppWeb, :live_view` make the DSL macros resolvable), `Mutare.Transform.Calls.resolved_call/1`, configurable mutators (`{module, opts}`), and `context.behaviours`.

## Goals

- **Mutate the Ecto an author writes** — query clauses, changeset validations, repo calls — at source level, in the forms idiomatic apps use (`from` keyword syntax *and* the composable pipe form; bare, aliased, and `use`-bundled imports).
- **Respect SQL semantics.** Every mutation is one a SQL engine will actually run, and the catalog's equivalence reasoning is SQL's three-valued logic, not Elixir's boolean lattice.
- **Stay inside the one compile.** Each mutation is delivered behind Mutare's runtime selector via `^`/`dynamic`, so the metamutant still compiles once and selects the active mutant at query-build time. No mutation may risk the single build.
- **Localized, reviewable mutations.** A mutation touches one clause, not the whole query; survivors render as one-line diffs of the logical change (`where: u.x == u.y` → `!=`), never the `dynamic` scaffolding.

## Non-goals

- **Reusing Mutare's built-in mutators inside a query fragment.** Rejected on purpose — see *The semantic boundary*. The plugin owns its fragment catalog end to end.
- **Mutating compile-time schema definitions.** `schema`/`embedded_schema` bodies are `:skip`ped: a mutated field name or type is a broken schema, not an interesting mutant.
- **Mutating generated reflection** (`__schema__/1`, changeset internals) or expanding Ecto's own macros. Mutation testing wants the human's source.
- **Cross-dialect SQL exhaustiveness.** The catalog targets portable, broadly-safe mutations; dialect-specific operators (JSON paths, full-text, array ops) are opt-in extras, not the core.
- **External-path targets.** The plugin requires the target app's deps (Ecto) on the BEAM code path for `use`-expansion and reflection, i.e. Mutare run *as a dependency of the app under test* — see *Deployment*.

## How it plugs in

One module, one config entry. The module is a `Mutare.Mutator` that also implements `macros/0` (auto-registering its DSL routing) and is configured with the app's Repo:

```elixir
# .mutare.exs
[
  mutators: [
    :all,                                  # keep Mutare's built-ins for ordinary Elixir
    {Mutare.Ecto, repo: MyApp.Repo}        # add the Ecto surface
  ]
]
```

Listing it both registers its macro routing (`Mutare.Macros.from_mutators/1` discovers `macros/0`) and enables its mutations. The `repo:` option arrives as `context.opts` in `mutate/2`. Internally `Mutare.Ecto` is a thin front for a **family of sub-mutators** (one per Ecto surface), dispatched by the node it sees; the `:as` opt convention lets a user run a sub-family under its own name in reports.

## The Ecto surface, in three buckets

Ecto's mutatable surface divides cleanly by *how a mutation is delivered* — and that division is the spine of the design.

| Bucket | Examples | Delivery | Core machinery used |
|---|---|---|---|
| **Plain calls** | `Repo.aggregate`, changeset validators, `Repo.get`↔`get!` | Mutare's ordinary in-place selector / pipe→identity | `Calls.resolved_call/1`, `{module, opts}` |
| **Skipped** | `schema`, `embedded_schema` | not mutated | known-macro registry (`:skip`) |
| **Hosted DSL** | `where`/`having`/`order_by`/`join`/… conditions | the `^`/`dynamic` host (#1), routed by `:hosted` (#2) | delivery host, shape-aware routing |

The first two buckets need **no new core machinery** — a basic plugin restricted to them ships against Mutare as it stands today. The third bucket is the heart, and what the two assumed extensions exist for.

### Bucket 1 — plain calls (ordinary delivery)

These are not DSL at all; they are remote calls resolved through `Mutare.Transform.Calls`, so direct, aliased, and `import`/`use`-bundled forms all match, and the mutation rides Mutare's existing delivery.

- **RepoAggregate** — `Repo.aggregate(q, :sum, :amount)` → swap the aggregate atom along SQL-meaningful ladders: `:sum`↔`:avg`, `:min`↔`:max`. (`:count` is left alone — swapping it changes arity semantics.) Matched by resolving the call's module to the configured `repo` and the function to `aggregate`; the atom sits in a known position. A ModeSwap-shaped mutation, delivered by the ordinary in-place selector.
- **ChangesetValidationDrop** — drop a transparent validation/constraint from a changeset pipeline: `cs |> validate_required([:x])` → `cs` (pipe form becomes `Function.identity()`, exactly Mutare's CallRemoval delivery; non-pipe `validate_required(cs, …)` → `cs`). Targets the `Ecto.Changeset` validators and constraints (`validate_required`, `validate_length`, `validate_format`, `validate_number`, `validate_inclusion`, `validate_subset`, `unique_constraint`, `foreign_key_constraint`, …). A survivor means *no test exercises the rule this validation enforces*. Resolved through `Calls`, so it fires under `import Ecto.Changeset` (commonly `use`-bundled). Pipe-aware via `mutate/2`.
- **RepoRaiseSwap** *(stretch)* — `Repo.get`↔`Repo.get!`, `one`↔`one!`, `insert`↔`insert!`: the raising/non-raising twins behave differently on the not-found / invalid path. Behavior-changing and compile-safe (same arity).

None of these touch the SQL fragment, so none use the host; they are SQL-adjacent at most (the *value* of an aggregate is SQL, but the swap is a plain atom in an Elixir call).

### Bucket 2 — the compile-time schema DSL (skipped)

`schema "users" do field :name, :string … end` is compile-time code that *defines* the struct. Mutating `:name` or `:string` produces a broken schema, not a mutant. The plugin registers it `:skip`:

```elixir
def macros do
  [
    {Ecto.Schema, :schema, :skip},
    {Ecto.Schema, :embedded_schema, :skip}
    # … plus the query macros, below
  ]
end
```

This works **only because** Mutare's `use`-expansion makes the `use Ecto.Schema`-injected `import Ecto.Schema` visible, so a bare `schema do … end` resolves to `Ecto.Schema.schema` and the routing fires. Without it the body would be analyzed as ordinary runtime code and poison the build. (The plugin ships nothing here beyond the registration; the visibility is Mutare's.)

### Bucket 3 — the query DSL (the host)

This is the design's reason to exist. A query clause cannot host a runtime `case` — it is macro-expanded into query AST at compile time, and you cannot reach `:persistent_term` from inside it. But Ecto's `^` interpolation + `dynamic/2` injects a runtime-chosen fragment that the query *actually runs*, and the active mutant is constant for a run, so exactly one branch bakes into the compiled query. That is the delivery host (#1) made concrete:

```elixir
# source
from u in User,
  where: u.age > ^min_age,
  where: u.x == u.y,
  order_by: [asc: u.name]

# metamutant (three localized, independent targets)
from u in User,
  where: ^case :persistent_term.get(:mutare_active, 0) do
           44 -> dynamic([u], u.age >= ^min_age)
           45 -> dynamic([u], u.age <  ^min_age)
           _  -> _ = MutareCov.hit_if_probe([44, 45]); dynamic([u], u.age > ^min_age)
         end,
  where: ^case :persistent_term.get(:mutare_active, 0) do
           41 -> dynamic([u], u.x != u.y)
           _  -> _ = MutareCov.hit_if_probe([41]); dynamic([u], u.x == u.y)
         end,
  order_by: ^case :persistent_term.get(:mutare_active, 0) do
           43 -> [desc: u.name]
           _  -> _ = MutareCov.hit_if_probe([43]); [asc: u.name]
         end
```

Two delivery shapes fall out of the `wrap` transform the plugin supplies per target:

- **Boolean/expression fragments** (`where`, `having`, `on`, a dynamic `select`) — `wrap` is `&dynamic([bindings], &1)`. The plugin extracts `[bindings]` from the enclosing `from` (or the pipe stage's binding list) and re-declares them inside each `dynamic`.
- **Pinned literals/keywords** (`order_by` direction, `limit`, `offset`) — `wrap` is identity; the value is simply `^`-pinned. `order_by: ^(case … -> [desc: …]; _ -> [asc: …] end)`.

Mutare owns everything structural: the selector subject, the `<id> ->` clauses, id assignment, the coverage catch-all, and the **Site** (recorded from the *logical* `original`/`mutants` — so the report diff is `where: u.x == u.y` → `!=`, the `dynamic`/`^` invisible). Because the emitted selector reuses Mutare's own subject and clause shape, **poison line-mapping and the manifest keep working unchanged** — the `^` is just an outer node over a selector Mutare already recognizes.

**Both query syntaxes are covered.** The `from` keyword clauses route as above; the composable pipe form `q |> where([u], u.x == u.y)` hosts identically — `q |> where([u], ^case … dynamic … end)` — since `where/3` accepts a pinned dynamic condition. The plugin's `macros/0` registers both, and the host handles the pipe placement the same way Mutare's `hoist_pipe` handles ordinary pipe stages.

**Binding reorder is the same mechanism.** Reordering a binding list `where([a, b], …)` → `[b, a]` is *equivalent to swapping the body's variable references* (under `[a,b]`, `a` is binding 0; expressing "binding 1's field" while keeping the declared list means writing `b`). Since each `dynamic` re-declares its own binding list, the plugin emits an alternative *body* (`dynamic([a, b], b.x == a.y)`) and rides the host — no special binding-reorder delivery path.

## Routing — which positions, which shapes

The plugin's `macros/0` declares the query macros and, via the shape-aware classifier (#2), routes each *argument by call shape*:

| Macro / form | Argument | Treatment |
|---|---|---|
| `from(p in S, where: p.x == v, ...)` (binding) | each clause expression | `:hosted` |
| `from(S, where: [x: v], ...)` (**bindingless**) | each clause's shorthand values | `:expression` (plain interpolated Elixir — *not* hosted) |
| `where(q, [bind], cond)` / `having`/`on`/… | binding list | `:pattern` (don't mutate in place; reorder is a host body-swap) |
| | condition | `:hosted` |
| `where(q, x: v)` (keyword shorthand) | the keyword values | `:expression` (plain interpolated Elixir — *not* hosted) |
| `order_by`/`group_by`/`distinct` | direction/expr | `:hosted` (pinned-keyword shape) |
| `limit`/`offset` | value | `:hosted` (pinned-literal shape) |
| `Ecto.Query.dynamic(...)` (nested) | binding / expr | `:pattern` / `:hosted` |

The shorthand-vs-expression split is exactly why shape-aware routing is required, and it appears at **two levels**. At the **macro** level: `where(q, category: "Foo")` is plain interpolated data (mutate `"Foo"` in place, no host) while `where(q, [u], u.category == "Foo")` is a hosted fragment. And **inside `from` itself**: a bindingless `from(Post, where: [category: "Foo"])` carries shorthand clause values (mutated in place), while a binding `from(p in Post, where: p.category == "Foo")` carries hosted expressions. The reliable signal is the clause value's **own shape** — a keyword list is shorthand (`:expression`); an expression referencing a binding is hosted — so a `from`'s first argument (`p in Post` vs bare `Post`) tells you which world its clauses can live in (and a binding `from` may still *mix* in shorthand clauses). A static per-position treatment can't express any of this; the `macro_routing/1` classifier inspects the actual node. The shorthand values are interpolated Elixir, so they fall under "pinned values are core's" — mutated by Mutare's normal literal families, not the SQL catalog (with the `nil`-pair exclusion below).

**`nil`-valued keyword pairs are excluded.** `where(q, deleted_at: nil)` compiles to `IS NULL`, not `= NULL`; the classifier routes a `nil`-valued shorthand pair to `:skip` so no value mutator perturbs it into nonsense. Null is the SQL family's job (below), delivered deliberately, not as an accident of literal mutation.

> **Implementation note (Milestone 3).** The shorthand split needed **two** core extensions beyond the original two, both since shipped:
>
> 1. *Per-keyword-pair routing.* `macro_routing/1` is per *visible argument*, and a shorthand clause list (`[category: "Foo", deleted_at: nil]`) is a single argument: routing it `:expression` mutates the column-name keys (meaningless) and the `nil` pair too; `:skip` mutates nothing; `call_option_keys: false` is all-or-nothing per mutator. So the classifier now returns `{:keyword, value_treatments}` for a keyword-list argument — core routes each pair's *value* by its own treatment and leaves every *key* raw, nesting for the `from(S, where: [x: v])` keyword-list-of-keyword-lists.
> 2. *Pinned in-place delivery (`:pinned`).* A second, subtler wall: a shorthand value sits **inside** Ecto's query macro, which rejects a bare selector `case` (`where(q, category: case … end)`) but accepts `where(q, category: ^(case … end))`. So core can't mutate a shorthand value with its ordinary in-place selector. The `:pinned` value treatment mutates the value with the configured literal families (their *own* names on the Site — the value mutation stays core's, recorded as `:literal`/`:string`, not `:ecto`) but `^`-pins the selector. Scalar-only (a compound value mutates nested nodes, where an inner `^` still poisons).
>
> The plugin routes each scalar `where`/`having` shorthand value `:pinned` and the `nil`/compound/key positions `:skip`. (Modern Ecto in fact *forbids* `where(q, col: nil)` outright — "comparison with nil is unsafe, use is_nil/1" — so the `nil`-pair exclusion is defensive; it can't arise in compiling code.) One known gap: a shorthand clause *mixed into a binding* `from` (`from(p in Post, where: [category: "Foo"])`) routes `:hosted` (for its binding conditions), so its shorthand value isn't split — the common shorthand forms are the bindingless `from` and the standalone/pipe `where`.

## The SQL-semantics mutator catalog

These are the plugin's **own** mutators, applied only inside hosted fragments and reasoned about in SQL's three-valued logic. They resemble Mutare's families by name only; their equivalence rules and inclusion decisions are SQL's.

| Family | Mutation | SQL note |
|---|---|---|
| **Comparison** | `>`↔`>=`, `<`↔`<=`, `==`↔`!=` | Boundary and equality coverage. `==`/`!=` interact with `NULL` (a swap changes which `NULL` rows are excluded) — a real, killable change; flagged for the equivalence report (below). |
| **NullPredicate** | `is_nil(x)`↔`not is_nil(x)`; `x == nil` is canonicalized as the engine sees it | The uniquely-SQL family; has no Elixir analog worth borrowing. |
| **Connective** | `and`↔`or` | Three-valued; killable but its equivalences differ from Elixir's — owned here, never reused from core. |
| **Membership** | `x in ^list`↔`x not in ^list`; `like`↔`ilike` | Polarity and case-sensitivity. |
| **Ordering** | `:asc`↔`:desc`; nulls placement `:asc_nulls_first`↔`:asc_nulls_last` | Pinned-keyword delivery. |
| **Aggregate** | in `select`/`Repo.aggregate`: `sum`↔`avg`, `min`↔`max`; toggle `distinct` | Bucket-1 form for `Repo.aggregate`; hosted form inside a `select`. |
| **JoinType** | `:inner`↔`:left` (and `:left`↔`:right`) | Changes result cardinality — a strong, killable mutation; only between join kinds the query is structurally valid under. |
| **Bound** | `limit`/`offset` `n`→`n±1`, drop `limit`/`offset` | Pinned-literal delivery. |
| **FragmentLiteral** | a *non-pinned* literal inside a fragment (`u.age > 18` → `19`) | The library owns in-fragment literals so it can keep them SQL-safe. |

**Pinned values are core's, not the plugin's.** A `^min_age` reference inside a query is a plain Elixir interpolation; the *value* `min_age` is bound in ordinary Elixir code upstream and mutated there by Mutare's normal Literal/Arithmetic families. The plugin's catalog targets the **fragment operators and structure** (the SQL-evaluated parts), leaving interpolated values to core. This is the clean version of the boundary: *Elixir values out, SQL structure in.*

**Deliberately excluded** (would be equivalent or unsafe under SQL): forcing a predicate to a constant where `NULL` makes "constant" a lie (the `Conditional`-style mutation); `/`-by-zero-prone arithmetic rewrites without a guard; anything that emits an Elixir construct (`nil` as falsy, an unpinned function call) the query engine can't run. When in doubt, the mutation is not offered — Mutare's poison backstop catches the residue, but the catalog aims not to rely on it.

## The semantic boundary (why no reuse)

It is tempting to run Mutare's `Relational`/`Arithmetic`/`Logical` tables inside a fragment through the `wrap` — code reuse, same operators. **This is rejected, categorically.** Mutare's mutators encode Elixir semantics and cannot vouch for SQL's, and the gap silently destroys recall. The canonical example, tied to Mutare's *equivalent-sibling suppression*:

```
a < b or a > b
```

Under two-valued logic this is constant (it is `a != b`, and the suppression may drop a redundant sibling mutant as provably equivalent). Under SQL's three-valued logic it is **`NULL` whenever `a` or `b` is `NULL`** — *not* constant. A reused mutator can therefore drop a genuinely-killable mutant, manufacturing a false negative at a semantic boundary it was never designed for. The similarity between the two operator sets is *syntactic*; the equivalence reasoning behind every mutation decision is *semantic*, and the semantics differ. So the plugin reuses Mutare's **delivery**, never its **mutation logic** — not even "the safe subset," because curation across the boundary is itself an Elixir-semantics judgment. This is the load-bearing design decision; the catalog above exists precisely so nothing has to be borrowed.

## Coverage, scoring, and the equivalence report

Coverage records at **query-build time** (the selector catch-all runs when the query is constructed), which is the honest proxy for "this clause was reached," and accumulate-only across builds — Mutare's existing model, unchanged. Scoring is Mutare's: a survivor is a located gap. Two Ecto-specific reporting refinements:

- **SQL-equivalence annotations.** A surviving `==`/`!=` or connective mutant on a nullable column may be *legitimately* unkillable without a `NULL`/boundary fixture — honest signal, but distinct from a flat "your test is missing." The plugin tags such families so the report can mark "kill requires boundary/NULL data" rather than implying a plain oversight.
- **No silent equivalents.** Because the catalog is SQL-native, it does not emit the Elixir-equivalent mutations (e.g. `x * 1`) that would inflate the denominator; what it cannot prove safe it does not offer.

## Configuration

```elixir
# .mutare.exs
[
  mutators: [
    :all,
    {Mutare.Ecto,
     repo: MyApp.Repo,                 # required: identifies Repo.* calls
     families: :all,                   # or [:comparison, :null_predicate, :bound, ...]
     dialects: [:postgres]}            # gate dialect-specific extras (JSON, ilike, ...)
  ]
]
```

- `repo:` — the app's Repo module; resolves `Repo.aggregate`/`get`/… regardless of alias.
- `families:` — narrow the SQL catalog (each sub-family is independently toggleable, and reportable under its own name via the `:as` convention).
- `dialects:` — guard mutations that are only valid (or only portable) on certain adapters; the conservative default is the portable core.

Multiple repos: list the entry twice with different `repo:` and `:as` names.

## Deployment

`mutare_ecto` requires Mutare to run **as a dependency of the app under test** (`{:mutare, …}` + `{:mutare_ecto, …}` in the app's `:dev`/`:test` deps), so the task process has Ecto and the schemas on its code path. This is what lets `use`-expansion expand `use Ecto.Schema`, reflection learn exported arities, and the host build valid `dynamic` calls. Running against an **external path** degrades: `use Ecto.Schema` won't expand, schema-skip silently fails, and the schema body poisons. The plugin should detect "Ecto not loadable" at startup and refuse loudly rather than degrade.

Ecto **version sensitivity** is real and owned here: which clauses accept `^dynamic` (e.g. `select: ^dynamic` is newer), the binding accumulation across joins, and dialect operators all drift with Ecto/adapters. The macro registry and the catalog's clause list are versioned artifacts the plugin maintains; Mutare core stays version-agnostic.

## Testing strategy

- **Unit (routing + weaving).** Drive `Mutare.transform_string/2` over fixture modules containing each query/changeset/repo shape; assert the recorded `Site`s (logical diffs + family names) and that the rendered metamutant **compiles** and parses back to recognizable selectors. No database needed — this tests that the right positions are routed `:hosted`/`:skip`/`:expression` and that the host wraps correctly.
- **Semantic (does the mutant run).** Against a real Repo (SQLite/Postgres sandbox), build each metamutant query under a chosen active id and assert the *dynamic actually changes the results* — proving the `^`/`dynamic` injection is live, not inert.
- **Boundary regressions.** Fixtures with nullable columns assert the catalog does **not** emit an SQL-equivalent mutant where three-valued logic would make it unkillable, and *does* emit the boundary mutant a missing-fixture test should catch.

## Milestones

1. **Buckets 1 + 2, zero core dependency.** Repo-call and changeset families + schema-skip, delivered by Mutare as it stands. Ships a useful plugin and proves the `macros/0` + `Calls` + `use`-expansion path end to end.
2. **The host (Bucket 3 core).** Comparison + NullPredicate + Connective on `where`/`having`, delivered via the #1 host and #2 routing. The distinctive piece; proves `^`/`dynamic` weaving with live mutation against a real Repo.
3. **Full query catalog.** Ordering, Bound, Membership, JoinType, Aggregate-in-select, FragmentLiteral, plus binding-reorder; the keyword-shorthand shape split and the `nil`-pair exclusion.
4. **Equivalence reporting + dialects.** SQL-equivalence annotations, dialect gating, multi-repo, per-family naming.

## Open questions

- **`select:` mutation reach.** How much of `select`/`select_merge` is safely dynamic-injectable across Ecto versions, vs left to whole-query (Bucket-1-style) replacement?
- **Subqueries and `fragment(...)`.** A raw `fragment("...")` is opaque SQL string interpolation — skip entirely, or offer string-literal mutations with a heavy equivalence caveat?
- **Build-time vs run-time coverage granularity.** Query-build coverage is a coarse proxy; is per-clause execution attribution ever worth chasing, or is build-time sufficient (it has been, everywhere else in Mutare)?
- **JoinType blast radius.** `:inner`↔`:left` is a strong mutant but can explode result sets on large fixtures — gate it behind a `dialects`/size heuristic, or trust the timeout?
- **How much dialect surface to own.** The portable core is clear; JSON/array/full-text operators are high-value but adapter-specific — plugin extras, or a separate `mutare_ecto_postgres`?
