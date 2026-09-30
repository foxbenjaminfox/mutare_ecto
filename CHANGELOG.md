# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Island mutations use core's `collect_expression/3` and `Mutation.map_node/2` to preserve
  their source attribution, producer, note and variants through nested query delivery.
  Hosted SQL mutations also retain their attribution: reports show the specific changed
  expression, and line-specific ignores can distinguish changes inside the same condition.
  This requires Mutare 0.4.2 or newer.

### Fixed

- Rebuild, instead of weaving, a `where`/`having` condition that is the literal `true` or has a
  mutant that is: Ecto's dynamic filter path discards such a condition, so a woven
  `where: false, or_where: true` returned no rows at baseline, and an `or_where` mutant to `true`
  delivered a different query than it reported. Rebuild, likewise, a condition whose pin or
  non-boolean literal takes the clause's own type (`where: coalesce(^flag, false)`): the static
  build casts it as `:boolean`, a `dynamic` as `:any`; `count(x, :distinct)`'s argument and
  `filter/2`'s aggregate pass the type on too. Both checks read through the `filter/1`
  Ecto's escape erases, and count a call Ecto may be expanding as a macro as possibly either.
- Under `EXISTS`, observe the projection when a grouping or `DISTINCT ON` term may name a
  projected column by position (`group_by: 1`, a `fragment`, a pin) past an offset or beside a
  `having`, and stop reading `group_by: nil` as grouping the query. A module attribute or macro
  in a grouping term may evaluate to either. A keyword `having` counts as reading a bare column,
  and an aggregate over only an enclosing query's columns (`max(parent_as(:outer).x)`) no longer
  counts as aggregating the subquery. Every such observation check now counts a call outside
  Ecto's query vocabulary, which Ecto can only be expanding as a macro, as unknown, whether or
  not the macro's routes are registered. The vocabulary is keyed by name and arity, as Ecto
  dispatches (an author's `coalesce/1` or `sum/2` is a macro), and a macro in the projection may
  define an alias.
- Leave a keyword filter's value unmutated where its column's type may `cast/1` it to another
  value (a custom type, `Ecto.Enum`, `:binary_id`): interpolated for its mutants, the value was
  cast where the written literal is only dumped, so the baseline bound a different value. The
  schema is read through the call site's aliases with `Mutare.CallRouting.Call.resolved_module/2`,
  new in Mutare 0.4.3, which is now the minimum; a module written as an atom
  (`:"Elixir.MyApp.Post"`) is read too. A source the plugin cannot read keeps the
  previous behaviour.
- Swap comparison, connective and `like`/`ilike` forms only at Ecto's arity 2: an author's
  `like/1` macro was swapped to a nonexistent `ilike/1`, failing the whole metamutant build.
  Read a remote `over/2` as an author macro, never a window: it crashed the transform.
- Read Ecto's names that are grammar of one position only (`map/2` in a select, `constant/1`
  as a fragment argument) as possible macros anywhere else.
- Stop pruning `min`/`max` swaps, and mutants inside them, beneath `is_nil`: on SQLite the
  aggregate also picks the row a bare column is read from.
- Read a window named in `over/2` (`over(row_number(), :w)`) from its `windows:` definition
  when judging whether an `EXISTS` projection mutant changes the query's aggregation, as the
  same options written inline are read; each use counts, so a drop that leaves another use
  keeps the aggregation. `over/2` is Ecto's own in every grammar (it had been read as a possible
  macro outside a window, keeping every mutant around a window).
- Read `as/1` and `parent_as/1` as Ecto's own only as a field's receiver (`as(:p).x`), and
  `map/2`/`struct/2` only over a binding variable: elsewhere Ecto expands a same-named macro,
  and a standalone `or_where: as(…)` expanding to `true` had been woven and lost its row.
- Stop counting an aggregate inside a macro's argument as certain when judging an `EXISTS`
  projection mutant: the expansion may discard it (`discard(sum(r.x))`), so a live drop of the
  query's only other aggregate was pruned.
- Read a window's function in its own grammar: Ecto takes only `Ecto.Query.WindowAPI`'s
  functions there and expands any other call, so `over(coalesce(a, b))` is an author's
  macro. Its `coalesce` drop had broken the whole metamutant's compilation, and an aggregate
  in its arguments had been counted as certain when judging an `EXISTS` projection mutant.
- Read `type/2`'s first argument in its own grammar: Ecto takes only the forms its `type/2`
  heads name there and expands any other call, so `type(is_nil(x), :integer)` is an author's
  `is_nil/1`. Its `not is_nil` swap had broken the whole metamutant's compilation, and an
  aggregate it expands to had been missed when judging an `EXISTS` projection mutant.
- Leave a select take's field list (`map(p, fields)`, `struct(p, fields)`) unmutated: Ecto
  expands it to a list of atoms at compile time. A macro there had been mutated as SQL, which
  broke the whole metamutant's compilation, and an `EXISTS` projection had counted it as an
  aggregate.
- Leave a fragment's template unmutated: Ecto expands it to a string at compile time, so a
  macro there (`fragment(sql(), x)`) had been mutated as SQL, breaking the whole metamutant's
  compilation.
- Read what `type/2` expands in a `having` as possibly a bare column when judging an `EXISTS`
  projection mutant, and a positional grouping through `filter/1` (`group_by: filter(1)` is
  `GROUP BY 1`): each had pruned a live projection mutant.
- Rebuild, instead of weaving, a condition whose string sigil (`coalesce(~s(0.5), false)`)
  takes the clause's `:boolean` type: Ecto escapes the sigil as a literal, cast differently on
  the dynamic path, so the woven baseline had returned other rows.
- Keep an `EXISTS` projection mutant that holds the same aggregates as the node it replaces
  when an author macro encloses it: the macro may read the syntax (`unwrap_sum(sum(x))`), so
  `sum` → `avg` had been pruned though it turned zero rows into one.
- Read `over` as Ecto's window only in the shapes its builder takes, a call-shaped function
  with at most a window description: `over(nil, x)` or an `over/3` is an author macro. One
  expanding to `true` had been woven into an `or_where`, changing the baseline, and one
  discarding an aggregate had had that aggregate counted when judging an `EXISTS` projection.
- Judge each call around an `EXISTS` projection mutant in the grammar Ecto reads it in:
  inside an expression, `merge/2` is an author macro that may read the mutated aggregate.
- Treat a pin that is a `dynamic`'s whole body as a parameter, not a keyword filter: core's
  mutants that change keyword keys inside it (`dynamic(^Keyword.get([value: 1], :value, 0))`)
  had been dropped, though Ecto never reads a keyword list there as a filter.
- Count an aggregate in a projection `fragment`'s argument as uncertain, and a projection
  `fragment` as possibly defining an alias, when judging an `EXISTS` projection mutant: raw SQL
  may make the aggregate a window function (`fragment("? OVER ()", count())`) or name an alias
  a `where` reads (`fragment("? AS n", x)`, on SQLite), and each had pruned a live mutant.
- Keep an inline subquery's `order_by` value mutant, without a window and under `EXISTS`,
  where it may change whether the query aggregates: an aggregate in `ORDER BY` makes Postgres
  aggregate the query (one row over empty input) and SQLite reject it, so
  `order_by: coalesce(1, sum(r.x))` → `1` changes the result. Such mutants had been pruned.
- Drop each occurrence of a repeated in-list element alone when it may evaluate differently
  each time (`p.id in [^next_id(), ^next_id()]`, `^provider.next()`, `^value[:id]`, a
  `fragment`): identical
  syntax had been read as one value, and the single-occurrence drop was never offered. A
  zero-argument remote call is no longer read as a field access where the plugin looks for
  calls Ecto may expand.
- Keep every `order_by` value mutant of an unwindowed inline subquery that may aggregate while
  a column neither grouped nor aggregated is observed: SQLite gives that column the row its
  lone `min`/`max` picks, even from `ORDER BY` (`order_by: min(r.x)` → `max(r.x)`).
  A window's inputs count too (`over(sum(r.y))`, `over(filter(sum(r.y), c))`,
  `over(fragment("first_value(y)"))`, `partition_by: :y`, a named window): a window
  runs over the aggregated rows, so its function's arguments are bare columns there.
- Read a non-empty `having` list the plugin cannot read as pairs (`[{:name, "Carol"}]`, which
  Ecto reads as a keyword filter) as possibly naming a bare column when judging an `EXISTS`
  projection mutant; it had been read as naming none.
- Read a named window written as an explicit tuple (`windows: [{:w, [order_by: sum(x)]}]`)
  from its definition, as the keyword spelling is: its aggregate had been missed when judging
  an `EXISTS` projection mutant. The explicit-tuple spelling is now read everywhere the keyword
  one is: a `DISTINCT ON` pair (`distinct: [{:asc, 1}]`), a window's options and sort pairs
  (`over(sum(x), [{:partition_by, y + z}])`) and an `order_by` direction flip, which had each
  been skipped, the first pruning a live `EXISTS` projection mutant.
- Leave a `dynamic` select map's keys unmutated, written or pinned (`%{p | title: "x"}`,
  `%{^:title => p.title}`): a key names a field of the result or of the updated struct, and
  its atom-literal mutant raised a `KeyError` when the results were loaded. A value is still
  data, a 2-tuple inside it included (`%{pair: {11, 22}}`).
- Observe an `EXISTS` projection that splices a pinned list (`fragment("max(?)", splice(^list))`):
  the list's length is the call's arity, which can turn SQLite's scalar `max` into its
  aggregate, so a core mutant of the list may decide existence.
- Rebuild, instead of weaving, a condition that splices (`fragment("? IN (?)", p.id,
  splice(^values))`): the dynamic path binds the spliced list once per placeholder, and the woven
  baseline failed with more parameters than placeholders.
- Hand core the pin in a named binding read through a dot (`as(^name).id`, `parent_as(^name).id`)
  and a window's pinned sort direction (`over(f, order_by: [{^direction, p.id}])`); neither had
  been reached.
- Hand core a pin nested in a compound cast type (`type(x, {:array, ^(if flag, do: …)})`), as a
  structural island: the walk skipped the whole type, and the pin's logic went unmutated.
- Drop each occurrence of a bare pinned variable in an in-list alone (`p.id in [^d, ^d]`): it
  may hold a `dynamic`, which Ecto expands afresh at each occurrence, so the two may differ.
  Dropping either of two identical such elements is offered once.
- Drop each occurrence of `ago/2` or `from_now/2` in an in-list alone: Ecto builds each on its
  own `DateTime.utc_now()`, so identical occurrences are distinct values, and dropping them
  together had replaced two live single-occurrence drops.
- Read `fragment()` as a macro Ecto expands (its fragment heads take at least the query): a
  `coalesce(fragment(), false)` drop had been woven into an `or_where`, where a `fragment()`
  expanding to `true` is discarded.
- Observe a window function beneath `is_nil` alike for `over/1` and `over/2`: the one-argument
  spelling offered the `sum` → `avg` swap the two-argument one prunes.
- Leave a binary literal's segments unmutated: `<<0>>` → `<<-1>>` is no query Ecto accepts, and
  failed the whole metamutant build. This holds in a projection and an ordering too, where the
  value walk had also read a size specifier as arithmetic (`<<0::unsigned-integer-size(128)>>`
  → `unsigned + integer`).
- Read a projection's select grammar only at its own level: `map/2` inside `coalesce` is an
  ordinary expression, where Ecto expands a same-named macro.
- Protect inline window grammar in free-standing dynamics, including opt-in atom mutations.
- Mutate list-valued dynamics and repeated explicit join predicates; permit hosting a sole
  explicit predicate on an association join.
- Retain projection mutations under `EXISTS` with `EXCEPT` or `INTERSECT`, and wherever else
  a projected value can decide whether a row survives: a `UNION` or projection `DISTINCT`
  followed by an offset, a `selected_as/1` read outside the projection, or a source query
  whose own clauses are out of view.
- Keep an `EXISTS` limit drop unless the limit it uncovers is known to match it in zero-ness:
  dropping `limit: 5` from `limit: 0, limit: 5` uncovers the zero, and a pinned limit may be
  zero at runtime.
- Withhold the `coalesce` drop where Ecto refuses the wrapped expression (a literal `nil`
  compared with `>`/`==`/…, a bare comparison as `type/2`'s first argument), which failed the
  whole metamutant build.
- Withhold the `coalesce` drop where it would leave a literal `nil` as an inline subquery's
  keyword-filter value (`where: [value: nil]`), or a pin where Ecto reads it as fields: a
  `select`/`select_merge`/`order_by` expression, an `order_by` entry, or a window option
  entry.
- Keep an `EXISTS` projection mutant that removes the query's only aggregate:
  `select: coalesce(0, sum(r.value))` is one row even over no input, while `select: 0` is none.
  An ordinary aggregate inside a window's operands or options counts, and a `having` does not
  fix the aggregation (Ecto drops a runtime-true one; SQLite rejects `HAVING` on a query that
  does not aggregate). A drop that keeps an aggregate in its retained operand is still pruned.
  The aggregation is read from the effective projection, after `select_merge` replaces earlier
  fields, a map update's pairs, or `merge/2`'s right operand. Under `EXISTS`, every
  projection pin except a query parameter reaches core: the whole projection, a map key, or a
  `map/2` take's field list decides which fields survive, and so whether the query aggregates.
  A windowed `fragment` counts as possibly hiding an aggregate.
- Observe an `EXISTS` subquery's projection where another clause may read it: a projection
  alias read through a pinned `dynamic` or a `fragment`, not only a written `selected_as/1`;
  and, on SQLite, a `having` that reads a column neither grouped nor aggregated, whose value
  comes from the row `min`/`max` picks.
- Mutate a value subquery's ordering when its source is a query, which may bring the `limit`.
- Beneath `is_nil`, mutate a window's partition and ordering keys: their values decide which
  rows the window function reads, even when their NULL-ness is unchanged.
- Include terminal composed subquery stages, inline subquery bounds, and windowed value-query
  ordering in mutation coverage.

### Added

- `condition_delivery: :static` preserves static condition building for opaque custom macros
  whose expansions cannot use Ecto's dynamic path.
- Native baseline and statically mutated query comparisons for delivery regressions.

## [0.3.0] - 2026-09-26

### Changed

- **Breaking: Mutare 0.4.1 or newer is required** (`{:mutare, "~> 0.4.1"}`). Mutare now hands
  a pipe stage to the plugin as the direct call it is sugar for, so the plugin reads a query
  source, a changeset, or a `Repo` write's value at argument 0 in both spellings, and the
  `pipe_left`/`pipe_mode` reading of 0.3.1 is gone.
- Query regions resolve through the public `Mutare.Analyze.resolve/2` API. Core reroutes
  rebuilt calls, so clause drops no longer need plugin-side routing-metadata repair.
- **A dropped pipe stage collapses to what flows into it.** `q |> where([u], u.active)` with
  the `where` dropped now reads `q |> where([u], u.active)` → `q` in the report, where it read
  `where([u], u.active)` → `Elixir.Function.identity()`; a stage in the middle of a chain is
  diffed over the pipe up to it (`q |> where(…) |> limit(10)` → `q |> where(…)`) and is still
  located at the stage's line. The same holds for a dropped changeset validator or hook and for
  the `persistence` rewrite of a piped `Repo` write, which now nests its `apply_action` chain
  around the piped value instead of emitting a pipe stage. The mutants and their kills are
  unchanged.
- **A source binding list piped into `from` is reordered too.** `([a, b] in q) |> from(…)` now
  gets the `binding_reorder` mutant (`[b, a] in q`) its direct spelling always had; through
  0.2.1 the piped declaration was read-only.

### Added

- **A CTE query pinned inline is mutated where it is written.** `with_cte("name", as:
  ^from(…))` now gets every mutant the same query gets when bound to a variable beforehand
  (`popular = from(…); … |> with_cte("popular", as: ^popular)`): the plugin's own SQL mutants
  inside it and Mutare's families on its Elixir. An `as:` written as SQL (`fragment("…")`) and
  the other options stay as written.

### Fixed

- Nested query macros no longer suppress the surrounding fallback condition mutants, such
  as comparison and aggregate swaps in a `having` containing `subquery(from(…))`, through
  Mutare 0.4.1's fix for macros inside raw/hosted syntax.

## [0.2.1] - 2026-09-19

### Fixed

- Computed `from` sources retain their upstream mutants, in both direct and piped forms.
  Schema aliases, table names and source tuples now stay unmutated on the left of composable
  query stages, just as they do in direct calls.
- Piped binding declarations (`(p in Post) |> from(where: p.views > 5)`) supply their bindings
  to hosted conditions. Whole-call rewrites, including clause drops, ordering flips and
  fallback condition rewrites, also run on this spelling. Source binding reorders remain
  unavailable because the left operand is read-only.

### Changed

- **Mutare 0.3.1 or newer is required** (`{:mutare, "~> 0.3.1"}`) for syntax-preserving
  pipe-stage delivery and the `Call.pipe_left` API used by source routing and binding discovery.

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

[Unreleased]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/foxbenjaminfox/mutare_ecto/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/foxbenjaminfox/mutare_ecto/releases/tag/v0.1.0
