# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building `mutare_ecto` —
the plugin-side counterpart of core's `../mutare/NOTES.md`. `CLAUDE.md` is the map and each
module's doc says what *is*; this file holds what's intentionally left for later and the
**design history** — what a thing used to be and why it changed — so moduledocs don't have to
read like logbooks. Referenced from code and docs as `NOTES "title"`.

## Deferred / known limitations

### Inner `from` inside a pin interior: whole-call rewrites only, no condition swaps — RESOLVED (in core) `[done]`

The full-set island sub-contract closed the inner-`dynamic` gap, but the analogous **inner
`from`** was only half covered: a standalone query built inside a pin interior
(`^repo.all(from p in P, where: p.x > 1, …)`) got `Query`'s whole-`from` rewrites through the
whole-call offer, while its `where:`/`having:` conditions' **in-fragment swaps** were produced
by nobody — at top level those are delivered by the selector host, and hosting was masked
inside the sub-contract (`host/2` disabled in collect), so the `:hosted`-routed condition
stayed raw.

The planned closing mechanism here was plugin-side (the `Mutare.Ecto.Subquery` pattern —
recurse the catalogs into the inner `from` and rebuild). What actually closed it is more
general and lives in core: collect no longer masks `host/2` — it runs a nested host's targets
through the same attachment the transform uses and **lowers** each target mutant to a
whole-call rebuild (`splice(wrap(mutant))`, exactly `HostedEmit`'s composition with the
selector degenerated to its selected branch — by construction the value the weave takes when
that mutant's branch is active). Hosting is a delivery optimization, not a semantic category:
where the weave is unavailable, the same mutant ships as the rebuilt call. Hosted *delivery*
still never nests (no selector is built inside an island); hosted *semantics* are never lost.

Consequences: the inner `from`'s condition swaps and literal arms now surface as
`where: ^dynamic(...)`-pinned rebuilds relayed through the outer weave, with zero plugin code
change — every host plugin gets this for free, per macro, with the producer's `finalize/2`
(the `families:` filter, the equivalence note) still running at generation. Proven by
`subcontract_test.exs` ("an inner from inside a pin"), the semantic fixture ("an inner from's
lowered condition mutant is live through the woven pin"), and core's
`subcontract_full_set_test.exs` (three delivery layers live at runtime).

### `apply_action`'s action atom: pinned against core's value families, never mutated `[done]`

Should the plugin mutate the second argument of `apply_action`/`apply_action!`? No — and it
should also stop **core** from doing so when core's families run alongside. The atom is
semantically inert where it matters: on a valid changeset it is never consulted
(`{:ok, apply_changes(changeset)}`), on an invalid one it only stamps `changeset.action` —
metadata whose one real consumer, Phoenix's form-error display, gates on `action != nil`, not on
*which* action. A swapped atom is therefore killable only by asserting the label itself — a test
about a name rather than about behaviour. The discriminator against the superficially similar
`:on_conflict` swaps: those fork real persistence behaviour (raise/skip/overwrite) with precise
kill conditions; this forks nothing observable.

Note the direction this cuts, which is not "the atom does not matter": tests *do* occasionally
read `changeset.action` (and `Ecto.InvalidChangesetError` prints it), which is exactly why
`RepoWrite`'s own rewrite has to reproduce whichever atom the real write would have stamped —
see the design-history entry "Persistence: the rewrite restates the write's Repo and action".
Mutating the atom is a cheap mutant we decline to offer; getting it *wrong* inside another
family's mutant is a spurious kill. Both say: reproduce it, never fork it.

So the surface is suppression shipped by the plugin, not mutation: `argument_marks/1` on
`Mutare.Ecto` declares `{Ecto.Changeset, :apply_action(!), 2, [1]}` under core's shared
`:structural` label — promoted in core for this case (`Mutare.Mutator.structural_label/0` +
`pinned?/1`; every `:skip_arguments`-honouring value family declines at the marked position; see
core NOTES "The `:structural` shared mark"). Rejected shapes: reusing `:timeout` (its readers are
value-aware — `AtomLiteral` holds back only `:infinity`, so the mislabel wouldn't even work);
forging the reserved `__mutare_self__.*` label (breaks under `:as`, abuses the namespace core
carved out); per-family user `:skip_arguments` config (works today but inverts ownership — every
app would re-encode plugin knowledge). Known limit: a mark pins the named node only, so
identifier-*list* positions (`validate_required(cs, [:name])`, `cast/3`'s permitted list) are not
coverable this way — the interior atoms are offered unmarked. If those ever need pinning, core
would need descent-propagating marks. Proven in `structural_marks_test.exs` (held back with the
plugin enabled, mutating without it — plus the piped/imported spellings and a positional
sibling-atom control).

### A macro that expands to a subquery in a `having`

`Mutare.Ecto.StaticCondition` declines to weave a `having` whose condition carries a subquery,
because Ecto rejects one inside a *dynamic* `having` when the query is built. It decides by
reading source (`Mutare.Ecto.Subquery.present?/1`), so a subquery that appears only once an
author macro **expands** is invisible to it:

    defmacro over_threshold(p), do: quote(do: count(unquote(p).id) > subquery(…))

    having: over_threshold(p) and count(p.id) > 1

That condition is woven, and the function then raises "subqueries are not allowed in `having`
expressions" on every call, baseline included. It takes both halves: a condition that is the
macro call *alone* has no catalog mutants, so it is never woven and builds as written.

No directive rescues it. `# mutare:ignore` marks the sites ignored but leaves the clause
woven — core drops a target whose mutants `finalize/2` all *skip*, not one whose sites are all
ignored. What does work is giving the macro a clause of its own, since repeated `having:`
clauses AND together: `having: over_threshold(p), having: count(p.id) > 1` weaves only the
second.

Closable plugin-side, and deferred as a delivery change rather than a fix. Reading source
cannot name the macro — core reports an unregistered macro as indistinguishable from an ordinary
call (`Mutare.Calls.routed_treatments/1`) — but it need not: inside a query expression every
call outside Ecto's own API (`Ecto.Query.API`/`WindowAPI`'s exports) is something Ecto must
macro-expand, so `weavable?/2` could refuse any such `having`. The recognized set cannot go
stale in the dangerous direction: a form it fails to recognize only downgrades that clause to
the whole-call delivery, which is valid either way. The cost is that every innocent macro in a
`having` (a `fragment` helper, say) gives up the weave too.

### A binding pattern on a pipe's left (`(p in Post) |> from(…)`) is unsupported

Ecto accepts `(p in Post) |> from(where: p.x > 1)` — `|>` rewrites it to `from(p in Post, …)`
before `from` expands — but the shape is pathological, and neither core nor the plugin can
serve it: core's pipe hoisting binds the left side to `mutare_piped` as a *value*
(`Kernel.in/2` on an unbound `p`), and the plugin's hidden-source `FromCall` (design history
"Piped `from`: the hidden source") declares no bindings for it, so a hosted `where:` would weave
`dynamic([], p.x > 1)`. Either would fail the single build. The plugin cannot guard it —
`Mutare.CallRouting.Call` carries only the visible arguments, so the left side's shape is
unseen — and core exposing the pipe-left is a core seam (consult before adding). Deferred until
someone writes it: the piped `from` in the wild is a bare or computed queryable on the left
(`Post |> from(as: :post, …)`), whose conditions reference named bindings or are keyword
shorthand, and those are exactly the shapes now covered.

### Subquery interiors: bounds and ordering are not composed

`Mutare.Ecto.Subquery` composes the row-set producers and (under a value-wrapper) the projection
swaps into an inline subquery, and leaves `limit`/`offset` and `order_by` alone. That used to be
recorded as a rejection on equivalence grounds ("inert under `exists`"), which is not true:
`exists(… offset: k)` asks for more than `k` rows, `limit: 1` → `0` empties the subquery, and
an ordering picks the row of a windowed or scalar subquery (`order_by: [desc: c.at], limit: 1`).
They are unimplemented. What composing them takes:

  * **per-shape gating** — the live set depends on the wrapper *and* the subquery: under
    `exists`, every `offset` mutant but of a `limit` only the bump to `0`; under a value-wrapper,
    ordering flips only when the subquery is windowed or scalar; a scalar `subquery`'s `limit`
    widened past `1` raises on Postgres and is equivalent on SQLite. `mode` alone
    (`:existence`/`:value`) does not carry that.
  * **a whole-`from` form of the bump** — `Mutare.Ecto.Bound`'s ±1 is hosted pin-only, which an
    interior (a whole inner `from` rebuilt as one branch of the outer weave) cannot use; only
    the bound *drop* (`Mutare.Ecto.Query`) composes as is.

The most valuable single case is probably the ordering flip of the latest-row scalar — "does
any test pin which row the subquery picks?".

### Spelling gaps: what the README table declares, and what closing each takes

The README used to say "both query syntaxes are covered", which was true of the families and
false of the capabilities: `Mutare.Ecto.Surface` declares what a name gets as a `from` key
(`:from`/`:from_drop`) and as a composable stage (`:mutations`/`:stage_drop`) independently, and
the two sides had drifted apart without any doc saying so. The README's "Coverage by spelling"
table now states each gap and `Mutare.Ecto.SpellingCases` pins it — comparing spellings by the
**statements their mutants reach**, since rendered diffs differ between spellings even where the
mutants agree. A gap is asserted as "this family reaches nothing here", so closing one fails
its test until the table is rewritten. None of the gaps below rests on an equivalence argument;
each is unimplemented.

  * **`clause_drop` on the `from` keys still held back** — `join:`, `select:`, `windows:`,
    `update:` (design history "Clause drop: the `from` keys nothing else needs"). Unlike a
    pipeline, a `from` shows every clause at once, so three of the four could be *constrained*
    rather than refused. A `join:` is the hard one: the keyword list expands at compile time,
    so dropping a join whose variable another clause reads fails the **single build** rather
    than one mutant. It has to prove the variable unreferenced (every other clause value,
    every other join's source and `on:`), take the join's own `on:` keys with it, and decide
    what a dropped `as:` name means for stages composed later. A `select:` could drop when
    the source is a schema rather than a table name, a `windows:` when no `over/2` in the same
    `from` names it. An `update:` cannot be decided here: whether `update_all` still has
    something to set depends on its call site.
  * **A computed `from` source** (`from p in recent(2)`). The source argument is an `in`
    pattern, and core's treatments are per argument: nothing routes "the right side of this
    `in`" `:expression` while the left stays raw. A nested treatment is a core seam.
  * **An inline piped subquery** (`subquery(Comment |> where(…))` inside a condition).
    `Mutare.Ecto.Subquery` recurses a parsed `FromCall`; a pipeline is a chain of stage calls
    with no such normal form, so each stage's condition would have to be located
    (`Mutare.Ecto.Host.Condition`) and rebuilt into the chain.

### Stage drops: a dependency break is not told from a weakened query

`Mutare.Ecto.ClauseDrop` emits both kinds under one family (its moduledoc has the taxonomy, and
`Mutare.Ecto.SpellingCases` pins where each break surfaces — build, plan, or run). A break is
killed by any test that executes the query, so it is scored as a kill that says nothing about
the dropped stage's effect; it also costs a mutant run.

It cannot be constrained from where the mutant is made: `mutate/2` is offered one stage, with
`pipe_mode` and nothing of the pipeline around it, and the stages that would reveal the
dependency may sit in another function altogether. Nor is a local proxy sound — a join naming
its binding or carrying `as:` is as likely to be a pure row filter as a provider. The options,
none taken:

  * **a sibling-aware seam in core** — the pipeline's later stages offered alongside the stage,
    which would also let a repeated pipe bound be recognised (design history "Bound: only the
    effective occurrence of a repeated bound is mutated"). Decidable only within one written
    pipeline; a query finished elsewhere stays opaque. Consult before adding.
  * **classifying the kill rather than the mutant** — core records `:killed` without the
    reason, so "killed by a raised `Ecto.QueryError`" is not reportable today. That is the
    general form of the problem, not an Ecto one, and would be core's to add.
  * **a separate family for the provider stages** (`join`, `windows`, `with_cte`), so a project
    could exclude them. Rejected for now: the filtering join is among the family's most useful
    mutants, and excluding by stage name discards it along with the breaks.

### Pins outside a condition are not sub-contracted

`Mutare.Ecto.Island` sub-contracts a pin's interior to core from the two places that own a
condition. Every other clause value is routed `:raw`, so `limit: ^(page_size + 1)`,
`order_by: ^[asc: dynamic([p], p.a + p.b)]` and `select: %{v: ^(min * 2)}` have interiors nobody
mutates, while the same code bound to a variable first is mutated where it is built. The
delivery is not the obstacle: the interior is already behind a pin, so a selector `case` there
is ordinary Elixir and poisons nothing. What is missing is an owner for the position —
either the host taking these values as `:hosted` targets, one per pin (the root-pin and
pin-only bound weaves in `Mutare.Ecto.Host.Target` are the precedent), or a core treatment
meaning "raw, except beneath a `^`". The second is a core seam; consult before adding.

### A structural queryable on a pipe's left is core's

`where(Post, …)` holds `Post` back from core's `:alias` family (a swapped schema is a broken
query — `Mutare.Ecto.Host.Routing`), and the piped `from` routes its hidden source `:raw` for the
same reason. A composable stage cannot do either: piped, the queryable is no visible argument,
the classifier never sees its shape, and routing the hidden side `:raw` wholesale would give up
every computed upstream query (`recent(2) |> where(…)`), which is the case the `:expression`
default exists for. So `Post |> where(…)`, a very common spelling, gets
`Mutare.Mutant |> where(…)`, and `"posts" |> where(…)` a query over `""`: each raises, and is
killed by any test that runs the query. Closing it needs core to show the classifier the pipe's
left side, the same seam "A binding pattern on a pipe's left" is waiting on.

## Design history

What a thing used to be, what it is now, and why. The moduledocs state only the current shape;
each entry here is the *before* they no longer carry.

### Persistence: the rewrite restates the write's Repo and action

`:persistence` swaps a Repo write for `Ecto.Changeset.apply_action/2`, on the promise that the
mutant differs from the real write **only when the write would have succeeded** — that is what
makes its kill condition ("a test drives a successful write and asserts a persistence
consequence") precise rather than incidental. The first rewrite emitted
`apply_action(change(arg), <action>)` and nothing else, which broke the promise twice on the
*failure* path, where the two are supposed to be indistinguishable:

  * `Ecto.Repo.Schema.put_repo_and_action/4` stamps the **Repo** on the error changeset;
    `apply_action/2` does not, so every persistence mutant returned `repo: nil`.
  * the `@writes` table fixed `:insert` as `insert_or_update`'s action, reasoning that "the atom
    only colours an error changeset's `:action`". But Ecto chooses that action **per call**, from
    the changeset data's `__meta__` state — a changeset over a row loaded from the DB routes to
    `update`. So an invalid *loaded* changeset came back `action: :insert` where the baseline said
    `:update`, and `insert_or_update!` raised "could not perform **insert**" against the
    baseline's "update". Any test asserting the rejection killed the mutant without ever
    exercising persistence: a spurious kill, and the expensive kind — it reports the write as
    tested when nothing tested it.

Both are now restated by the rewrite: a `Map.replace!(…, :repo, …)` stage carrying the configured
`repo:`, and — for `insert_or_update` only — a `Kernel.then/2` binding whose `fn` reads
`Ecto.get_meta(changeset.data, :state)` and picks the same action Ecto would (binding rather than
re-reading the argument, which must not be evaluated twice). The two written forms come from one
`stages/3` table folded either into nested calls or into a pipe, so the piped and unpiped mutants
cannot drift apart the way a hand-written pair can. Deliberately still unreproduced:
`changeset.repo_opts` (the real value can carry a live process stacktrace) and Ecto's argument
guards on `insert_or_update` — see `Mutare.Ecto.RepoWrite`'s moduledoc. Proven in
`repo_write_test.exs` and, against both engines, by the semantic suite's "the mutant's *failed*
write is byte-for-byte the baseline's".

### `repo:` takes a list; `:as` only names

`repo:` accepted exactly one module, and the documented way to cover a second repo was to list the
plugin twice with `repo:`/`as:` — which also split the report into two families and doubled every
`# mutare:ignore[…]` label, though a survivor's file:line already says which repo it hit. The
sibling `mutare_swoosh` plugin took a list for its `mailer:` from the start, so the two gave a
third plugin author two rules to copy. Now both take one module or a list, normalised at `init/1`
into `Mutare.Calls.module_key/1`s, and `:as` is reserved for what it does everywhere in Mutare:
naming the report family. The one place the single-repo assumption had leaked into a mutant — the
`:persistence` rewrite's `Map.replace!(…, :repo, …)` stamp, which read the *configured* repo — now
takes the repo the call *resolved to*, which `Mutare.Ecto.RepoCall.resolve/2` returns alongside the
call for exactly that purpose (`repo_write_test.exs`, "with several repos configured").

### Tag: one shape instead of three tuple arities

Producers used to return a mutation as one of three tuples — `{family, node}`,
`{family, node, label}`, `{family, node, label, attribution}` — and every consumer that bridged
two producers (a walker rebuilding a clause, a host composing catalogs) had to pattern-match all
three. `%Mutare.Ecto.Tag{family, node, label: nil, attribution: nil}` replaced them: one shape
with `nil` defaults, `Tag.map_node/2` as the shared "rebuild the surrounding form around each
mutant" step, and `Tag.to_mutation/1` as the one normalizer both delivery paths return through.
Adding a finer label to a producer no longer touches delivery code.

### Walk: one traversal under every catalog

`Fragment`'s mutation walk and its island walk were two hand-rolled copies of one traversal, and
the `select`/`order_by` expression walker a third — three descents that could disagree about
which nodes a condition exposes (an island the catalog would never have walked past, or the
reverse). `Mutare.Ecto.Walk.positions/3` is now the single traversal; every catalog is a per-node
*reader* over its positions and never descends on its own (a catalog's `children/2` rule can only
narrow what the walk admits). So `Fragment.mutants/2` and `Fragment.islands/2` agree by
construction, not by two walks kept in step; `fragment_descent_test.exs` pins the policy.

### Dispatcher: classify once

The original dispatch was flat: every AST node was offered to all eight sub-mutators, each of
which re-ran macro and call resolution — even for ordinary literals and operators that no
producer could ever claim. `Mutare.Ecto.Dispatcher` classifies a node once (a registered query
macro by its `Surface` kind, otherwise the resolved call's module — `Ecto.Query`,
`Ecto.Changeset`, or the configured repo) and invokes only the producers that can apply.

### Bound bump: from whole-call rewrite to pin-only hosting

The `±1` bump of a literal `limit`/`offset` first lived beside the other clause mutations —
`Mutare.Ecto.Clause` rebuilt the standalone/pipe call and `Mutare.Ecto.Query` the whole `from` —
so each bump duplicated the entire call/query per mutant, exactly the cost the selector host
exists to avoid. It is now **hosted, pin-only**: `limit: ^(case …)` with no `dynamic/2` wrap and
no bindings, because a bound is an integer parameter and the pinned selector is plain Ecto
interpolation with a behaviourally identical baseline (`Mutare.Ecto.Bound`, `Host.Target`).
`Bound.literal?/1` is defined as `bumps/1` being non-empty, so the routing classifier and the
host agree on "literal bound" by definition. Only the bound *drop* remains a whole-`from`/stage
rewrite.

### Root pin: from `dynamic`-wrapped to pin-only

When a top-level-pin condition (`where: ^cond`) was first hosted in every form, it rode the
ordinary delivery: every branch `dynamic(bindings, ^interior)`. The interiors that change had
in view were a runtime boolean and logic choosing which dynamic to splice, and its check was
that every woven metamutant *compiles*. A `DynamicExpr` does survive the wrap (`dynamic/2`
splices it), and that was the one arm ever observed at runtime (the semantic suite's
inner-dynamic fixture); the later keyword-filter fixtures again asserted compilation only. But
Ecto dispatches a root interpolation on its value, and inside `dynamic/2` the same pin is a
parameter: `^[score: 5]` stopped being `p.score == ^5` and became the parameter `[score: 5]`
(an `Ecto.QueryError` when run), and `^true` became a bound `true` instead of no condition. Since
the wrap also encloses the *original* branch, the instrumented **baseline** broke, not just the
mutants; the trigger was any core-mutable Elixir in a root pin whose value is not a
`DynamicExpr`. A root pin is now woven **pin-only** over its bare interior, by the branch `wrap`
alone — which also fixed the lowered rebuild of an inner query's root pin, since core lowers
through the same `wrap` (`Mutare.Ecto.Host.Target`; `root_pin_delivery_test.exs` holds the
baseline-parity check across every arm of Ecto's dispatch and every hosted position).

`Host.Target` first told a root pin by matching the written `^` itself — a second reading of a value
`Mutare.Ecto.Host.Condition.shape/1` had already classified, as a predicate. The kind is now part of
that one classification (`{:predicate, :root_pin}` beside `{:predicate, :expression}`), carried by
`locate/1`'s struct and the host's keyword-value paths into every condition target, so the same
decision says whether the host owns a value and how it weaves it.

### Ordering: implicit-direction flip replaces the order_by clause drop

`order_by` used to be droppable like any other clause. But an `ORDER BY`-less query's row order
is SQL-unspecified, so whether the drop was "killed" depended on the engine happening to return
rows in a different order — the mutant's survival tracked engine nondeterminism, not the test
suite. The drop was removed (`order_by`/`prepend_order_by` carry no `stage_drop`/`from_drop` in
`Surface`) and replaced by re-tagging a bare, implicitly-ascending ordering term (`:name`,
`u.name`) to an explicit `desc` — a `:ordering` mutant with a deterministic, behaviourally
distinct baseline, sound because bare-means-ascending is Ecto's own guarantee, engine-independent
(`Mutare.Ecto.Ordering`). It asks the question the drop was pretending to ask.

### Ordering: one axis per mutant

A nulls-qualified sort key used to flip both axes at once (`:asc_nulls_first` →
`:desc_nulls_last`). That was a *weaker* mutant: any order-pinning test killed it, so a missing
NULL-placement assertion never surfaced. Each axis now flips on its own — direction under
`:ordering` (keeping the placement), placement under `:ordering_nulls` (keeping the direction,
only for an explicitly qualified key, and equivalence-sensitive because it needs NULL rows to
kill). A bare `:asc` yields one mutant; an `:asc_nulls_first` yields two.

### JoinType: narrowing only, no introducing swaps

The join family once offered *widening* swaps — `inner_join`/`join` → `left_join`, `*` →
`full_join` — that **introduced** a join kind the author never wrote. They were mostly equivalent
(a join written to exclude unmatched rows rarely has an orphan for the widened query to expose)
and each needed a dialect gate for the introduced kind. The family now only narrows
(`left_join` → `inner_join`, `full_join` → `left_join`/`right_join`) plus the sideways
`left_join` ↔ `right_join`; every flip permutes a form already reachable from the source, so the
remaining gates (`RIGHT JOIN` under `:postgres`/`:mysql`) are purely about the *target* kind's
portability (`Mutare.Ecto.Query`).

### JoinType: one catalog for both spellings

The join-kind flips used to be two maps inside `Mutare.Ecto.Query`, keyed by `from` clause key
(`left_join: [:inner_join]`), and the only thing that read them was the whole-`from` key swap —
so `join(q, :left, …)` kept its qualifier, a gap nobody had decided on (it surfaced when the
spellings were first compared by the statements they reach). The flips are keyed by
**qualifier** now, the one name both spellings write, in a shared `Mutare.Ecto.JoinType`
catalog beside `Mutare.Ecto.Combination`: `Query` converts a join key to its qualifier and the
targets back, `Mutare.Ecto.Clause` swaps the qualifier argument in a whole-call rewrite, and
the policy, the `dialects:` gate and the `# mutare:ignore` labels are the same by construction
rather than by parallel maintenance. Only a literal qualifier is swapped: Ecto accepts a
computed one (validated at runtime, `Ecto.Query.Builder.Join.qual!/1`), which is a value
mutated where it is bound.

### Surface: one descriptor table instead of parallel lists

Routing kind, stage-drop family, whole-`from` drop family, hosted/binding/join capabilities, and
standalone mutation capabilities were once kept in parallel lists across the modules that
consumed them; adding a query builder meant finding and updating each. `Mutare.Ecto.Surface` is
the one descriptor table (with compile-time invariant checks per descriptor), every consumer
derives its view from it, and `macro_kind_parity_test.exs` pins that each dispatch on
`macro_kinds/0` takes a real branch for every kind.

### ClauseDrop: the pipe form was the common one

The clause drop — "is this filter/window/grouping tested at all?", the primary motivating
mutation for a query builder — was originally only reachable in the `from`-keyword syntax, as
`Mutare.Ecto.Query`'s whole-`from` clause drop. The composable pipe/standalone forms
(`q |> where(…)`) are far more common in practice, so `Mutare.Ecto.ClauseDrop` added the stage
drop over the shared `Mutare.Ecto.StageDrop` delivery, recording the **same** family as `Query`
for the same semantic mutation regardless of which syntax wrote it.

### Clause drop: the `from` keys nothing else needs

After `Mutare.Ecto.ClauseDrop` gave every composable stage a drop, the `from` form was left
with the two it started with — `where`/`having` (`:filter_drop`) and `limit`/`offset`
(`:bound`) — so `q |> group_by(…)` could lose its grouping and `from(…, group_by: …)` could
not. No decision lay behind that; it surfaced when the spellings were compared by the
statements their mutants reach. `Mutare.Ecto.Surface` now declares `from_drop: :clause_drop` on
`group_by`/`distinct`/`preload`/`lock`/`select_merge`/`with_ties` and the six set operations,
through `Mutare.Ecto.Query`'s existing `drops/3` (so a repeated `lock:` drops only its effective
occurrence, like a repeated bound).

The line is drawn by what a `from` is: one keyword list, expanded as a whole when the
metamutant compiles, where a pipeline is assembled at runtime. A stage drop that breaks a
dependency raises under its own mutant; the same drop in a `from` can fail the **build** for
every mutant in the file. So a key drops only if the rest of the list cannot need it — it
binds no variable, nothing names it, no plan requires it — which holds back `join:` (binds a
variable), `select:` (a schemaless source requires one), `update:` (`update_all` does) and
`windows:` (named by `over/2`). `Surface` enforces that a `from_drop` is the same name's
`stage_drop` family, and `surface_test.exs` pins the held-back set, so a clause macro added
later has to be placed on one side of the line. What is left can still fail at the *engine*
(a projection that needs its `group_by` on Postgres), under that one mutant.

### Fragment: beneath `is_nil`, pruned only where NULL-ness is known

`is_nil`'s argument used to be a hard boundary for every family: the walk never entered it, on
the claim that the value families preserve NULL-ness, so that any mutant there is equivalent. A
first correction read the coalesce drop — the one mutation *named* as NULL-ness-changing —
beneath it through a narrowed walk of the unit's own (`is_nil(coalesce(u.name, u.role))` →
`is_nil(u.name)` is live for a nullable default), and kept the boundary for everything else,
islands included.

The claim itself was too strong, for the catalog's own families and for everything around them:
`*`→`/` turns a product NULL on a zero divisor (SQLite, MySQL; Postgres raises); `and`↔`or`
is three-valued; a literal is data wherever a form's NULL-ness depends on a *value* — the
comparand of `fragment("NULLIF(?, ?)", p.score, 0)`, a JSON path key, a divisor; and a pin's
interior is Elixir that can compute `nil` by any route (`^(opts[:min] || default)`), which the
boundary kept from core altogether. So the boundary is gone. The argument is ordinary descent
under a narrower *observation* (the walk's context carries `:nullness` beneath `is_nil`), and a
mutant is pruned only when one table of per-form NULL rules (`Mutare.Ecto.Fragment`'s
`nullness/1`: literals, `+`/`-`/`*`, `coalesce`, the four aggregates) shows it NULL on exactly
the original's rows; the same table decides how far down the narrow observation reaches.
Everything outside the table is unknown and emitted — the error now costs an equivalent mutant
in code nobody writes (`is_nil(p.a > 1)`), where it used to cost live ones. Pinned in
`fragment_test.exs`/`fragment_descent_test.exs`/`subcontract_test.exs`, and live on both
engines in the semantic suite (the `NULLIF` literal, the connective, the pin).

### Fragment: a tuple is told by position, not refused wholesale

`Mutare.Ecto.Fragment`'s walk used to refuse every 2-tuple as a leaf, on the claim that the only
tuple a condition contains is a compound cast spec (`type(x, {:array, :string})`) — whose
literals are structural at every depth, beyond the reach of the structural-position registry
(which names only a form's direct argument). The claim missed Ecto's tuple comparison,
`{p.views, p.id} > {1, 2}` (SQL's row-value comparison, supported since Ecto 3.0): the swap
fired on the `>`, but the literals inside the tuple were never mutated and a pinned element was
never an island — while the `{:{}, …}` form of a wider tuple, which the refusal did not match,
*was* entered, with its elements at a `{:{}, n, i}` position no registry entry names. The walk
now tells the two roles apart by position: at a structural position either tuple form is a cast
spec and stays a leaf; anywhere else it is a value tuple, transparent like a written list (its
elements inherit the comparison's position, so they are data). Pinned in `fragment_test.exs`,
`fragment_descent_test.exs`, and live against both engines in the semantic suite.

### Fragment: element drops shrink the set, not the written list

The in-list element drop used to be one mutant per *index* of a written list, deleting that
position: `p.id in [1, 1, 2]` offered `[1, 2]` twice and `[1, 1]` once. SQL `IN` is set
membership, so a duplicated member made the per-index drop dead by construction — deleting one
`1` leaves the other, the set `{1, 2}` is unchanged, and no test can tell the mutant from the
original (twice over). The drop is now one mutant per *distinct* written element, removing every
occurrence (`Mutare.Ecto.Fragment`'s `element_drops/1`): `[1, 1, 2]` shrinks to `[2]` and
`[1, 1]`, each a different set. Elements are compared as written expressions with their source
metadata stripped, so `^a`/`^a` and `u.x`/`u.x` are one member exactly as `1`/`1` are; a
duplicate-free list is unchanged. The literal bumps *inside* a duplicated list are still per
node (bumping one `1` of `[1, 1, 2]` to `2` gives `[2, 1, 2]`, the original set): rewriting every
occurrence would be a multi-point rebuild the walk does not offer.

### Routing: the threaded query by form, not shape

`Mutare.Ecto.Host.Routing` used to decide whether a composable macro's first argument was the
threaded query by **shape** — a bare variable, a nested pipe, or a call whose name was a
registered query builder (`Surface.query_builder?/1`) routed `:expression`; anything else
`:skip`. The shape test stood in for the one fact that actually places the query — whether the
call is piped — and it was wrong for every legal computed queryable: `where(base_query(2), …)`,
`where(if(…), …)`, `where(Ecto.Query.exclude(q, :order_by), …)` all routed `:skip`, so core never
descended them and `base_query(2)`'s `2 → 3/1/0` silently vanished (while the same call piped,
`base_query(2) |> where(…)`, kept them through `from_visible`'s default). The classifier now
routes by core's `pipe_mode`: piped, no visible argument is the query; direct, the first one is,
and it routes `:expression` whatever its shape. The only shape still read there is the structural
queryable (a schema alias, a table-name string, a `{"table", Schema}` pair), which stays raw
because a table/schema swap is a broken query, not a mutant. `Surface.query_builder?/1` went with
the heuristic.

### Piped `from`: the hidden source

`Post |> from(as: :post, where: as(:post).views > 5, limit: 5)` used to receive **no** mutations
at all — no comparison, no literal, no filter drop, no bound — while the identical
`from(Post, as: :post, …)` received eight. `Mutare.Ecto.AST.FromCall` took the source from the
argument list, so a piped `from`'s one visible argument (the clause list) landed in the source
slot; `Mutare.Ecto.Host.Routing` then stamped it `:skip`, and the host and `Mutare.Ecto.Query`
each parsed a clause-less `from` and produced nothing. `FromCall` now places the clauses by the
call's `pipe_mode` (`Mutare.Ecto.AST.QueryCall` carries core's stamp): piped, the source is
`nil` — hidden, on the pipe's left — and every edit rebuilds the `from(…)` half at its written
arity, so the routing classifier, the host splice, and the whole-`from` rewrites all read the same
shape and the two spellings yield the same mutants. The hidden source itself routes `:raw`
(`route_arguments/2`'s `piped:` override — the plugin never sees its shape, and `from`'s source
is never routed in the direct form either), which also stops core's `:alias` family from swapping
a structural `Post |>` for a nonexistent module, as `from_visible`'s `:expression` default had let
it. Inside a subquery, the inline-`from` finders (`Mutare.Ecto.Subquery`) still recognise only
the direct spelling — a `subquery(Post |> from(…))` interior stays out of reach.

### Aggregate: only Ecto's own `/1` aggregate is on the ladder

`Mutare.Ecto.Aggregate`'s per-node catalog used to match `{f, meta, args} when f in @agg_funcs
and is_list(args)` — any call wearing the name, at any arity. The `is_list` half was only ever a
crash guard (a bare variable's third slot is its hygiene context, not arguments); nothing checked
that the call was Ecto's. Every rung of the ladder is `/1`, so the pattern claimed calls Ecto does
not define, and a rename across the ladder emitted a call *nobody* defines: an author's
`sum(a, b)` — a query DSL is free to define one, and `Kernel.min/2`/`max/2` already are two —
became `avg(a, b)`, which Ecto's builder rejects while expanding the query
(`** (Ecto.Query.CompileError) avg(p.views, p.likes) is not a valid query expression`). That is a
failed **build**, not a wasted mutant: the metamutant embeds every mutant in one compilation unit,
so a single mis-swap takes the whole run down.

`Mutare.Ecto.Walk`'s author-macro rule did not cover this. It governs descent *into* a registered
macro's arguments — `select: clamp(sum(p.x), 10)` never has its `sum` swapped — but the macro call
node is itself a walk position, offered to the catalog by its parent, so a macro *named* `sum` was
mutated however it was routed. The catalog now guards both halves of "is this Ecto's aggregate":
the arity (`[_arg]`, the same binary/`/2` guard `Mutare.Ecto.Scalar` already carried for
arithmetic and `coalesce`), and ownership — Ecto's aggregates are plain `Ecto.Query.API`
functions, never routed macros, so a resolve-pass macro stamp (`Mutare.Calls.macro_treatment/1`)
proves the call belongs to somebody else's grammar. The name-collision fixture is the plugin's own
`Mutare.Ecto.AuthorMacros`; core's shipped `RoutingExtension` cannot stand in for it, because its
macros are named nothing the plugin mutates.

### Bound: only the effective occurrence of a repeated bound is mutated

Both arms of the `:bound` family used to fire on **every** `limit:`/`offset:` clause of a `from`.
But Ecto applies a `from`'s pairs in written order, and `limit`/`offset` (and `lock`) *replace*
their predecessor — "if `limit` is given twice, it overrides the previous value" — where every
other key accumulates. So for `limit: 5, limit: 10` the built query only ever held the `10`, and
the three mutants on the `5` (both bumps and its drop) were equivalent by construction: no test
could tell them from the original. `Mutare.Ecto.Surface` now declares the last-wins keys
(`last_wins?/1`), `Mutare.Ecto.AST.FromCall.effective_clause?/2` turns that into "the clause at
this index reaches the query", and both producers consult it — `Mutare.Ecto.Query` before a drop,
`Mutare.Ecto.Host` before weaving a bump. The final occurrence keeps all three mutants; its drop is
live because it uncovers the previous one. The rule follows the same reasoning as the `IN`-list
element dedupe above: a mutation that provably leaves the built query unchanged is not offered.
Only the `from` keyword form is in view — a bound repeated across a pipe
(`q |> limit(5) |> limit(10)`) or across functions composes at runtime, where no single node sees
both occurrences, so those stay mutated (suppressing the pipe form would need a sibling-aware
seam in core).


### Bindings: an unnamed join still holds its slot

`Mutare.Ecto.Host.Bindings.from/2` used to build a `from`'s binding list out of the joins that
*declare a variable* — it matched `join: c in Source` and passed over everything else. But Ecto
binds a join written without `x in` (`cross_join: "audit"`, `join: subquery(q)`,
`left_join: assoc(p, :x)`, a `fragment`, a `^source`) anonymously, and still advances the binding
count. So for `from p in "posts", cross_join: "audit", join: c in "comments", …` — `p` &0, the
audit join &1, `c` &2 — the host wove `dynamic([p, c], …)` and named &1 `c`.

That was worse than a bad mutant. Every branch of a hosted selector resolves through the
re-declared list, the *original* condition's included, so the miscount rewrote the **baseline**;
and a misplaced binding raises only if the table it lands on lacks the column the condition reads.
Where the two tables share that column name the SQL was valid over the wrong table — the
instrumented query ran and returned the wrong rows, invisible to `assert_compiles`.

Each join now yields exactly one slot (`join_slots/1`): its variable, or the `_` placeholder
(`Mutare.Ecto.Binding.placeholder/0`). A `...` could not have repaired it, because the miscount
runs in both directions: under a literal source slots count from the front, so a dropped slot
displaces the joins *after* it; under a composed source the `...` anchor counts from the tail, so
it displaces the joins *before* it (`[p, ..., c]` named a trailing audit join `c`; the list is
`[p, ..., c, _]`). For the same reason a trailing `_` is kept rather than trimmed. `host_test.exs`
checks positions against Ecto itself — the metamutant's baseline must build the query the untouched
source builds, over every named/unnamed pattern of one to three joins and both source kinds — and
the semantic suite runs the placements against `comments`/`audit`, two tables seeded with the same
columns so that a wrong slot returns different rows rather than an error.

The standalone `join/4,5` never miscounted — it re-declares the author's own written list and
tail-anchors the one join it adds — but only because it declined an unnamed join altogether:
`Bindings.join/1` matched `x in Source`, wove nothing for a bare `Source`, and the `on:` of
`join(q, :inner, [p], "audit", on: …)` kept only its stage drop. It now takes the join's slot from
the same `join_slot/1`, so that `on:` is hosted behind `[p, ..., _]`. The placeholder is
load-bearing there too: the `on:` is resolved with the new join in place, so after an
author-written `[..., x]` the list must be `[..., x, _]` — `[..., x]` alone would read the new
join as `x`.

Hosting unnamed joins exposed the same blind spot in `Mutare.Ecto.Host.JoinOn`: its `assoc`
exclusion matched `x in assoc(p, :rel)` only, so a bare `assoc(p, :rel)` join slipped past it (in
the `from` form its `on:` was already being hosted). An `assoc` join is now told by its source,
named or not.

### Condition: predicate or keyword filter, decided once

Whether a condition-position value is a predicate or a keyword filter used to be decided in
several places that did not agree — or not decided at all. The `from`-clause classifier asked
for a non-empty keyword list (`KeywordList.nonempty/1`); the binding-less argument form refused
any list; the binding form (`where(q, [p], …)`) asked nothing, treating whatever followed a
binding list as a predicate; and the host asked nothing either — `from_targets/2`, the join
target and `Mutare.Ecto.Subquery` applied the predicate catalog to every value whose **key**
admits a condition. `Mutare.Ecto.Fragment`'s doc promised `[]` for a keyword shorthand, but its
walk enters a written list and reads a `score: 5` pair as a value tuple, data on both sides.

Two shapes fell through. `where(q, [p], score: 5)` routed `:hosted`. And in
`from(p in "posts", where: [score: 5], limit: 10)` the classifier routed the pairs to core
correctly, but the hosted `limit:` made core offer the *whole call* to the host (core does not
confine returned targets to `:hosted` positions), which then claimed the sibling filter as well.
Either way the list was wrapped as `dynamic([p], score: 5)` — Ecto's general expression builder,
which refuses a filter's pairs — so the metamutant failed to compile; the host's splice also
overwrote the pins core had placed inside the list, leaving core's recorded mutants with no
selector branch; and with the opt-in atom arm on, the catalog renamed the column
(`[mutare: 5]`). The same held for a join's `on:` shorthand, and for a pinned pair value
(`where: [score: ^(min + 1)]`), whose interior — nobody's, by `pair_treatment/1` — was
sub-contracted to core as soon as a sibling was hosted. The existing mixed-shorthand test used
`[active: true]` under the default families, where the boolean arm is off and the catalog finds
nothing, so it never exercised any of this.

`Mutare.Ecto.Host.Condition.shape/1` is now the one classification — Ecto's own rule: a written list
literal is the filter builder's, anything else the host's (an expression, or a root pin Ecto
dispatches on its runtime value — "Root pin: from `dynamic`-wrapped to pin-only") — read by the
classifier, by both argument forms of `locate/1`, by the host's keyword-value paths, by the subquery
recursion, and by the host's whole-call fallback (`Mutare.Ecto.StaticCondition`), which would
otherwise take a subquery-bearing filter (`having: [score: subquery(…)]`) for a declined predicate
and catalog its keys. The subquery case differs in one respect, kept deliberately: an interior
mutant is delivered as the inner `from` rebuilt, so a filter there stays in a filter position and
its pair *values* are still the plugin's to mutate (the whole outer condition is hosted; core never
reaches them) — only the keys stopped being catalog roots. Pinned in `shorthand_test.exs` —
including the compositional regression (a hosted sibling changes neither the diffs recorded in a
shorthand nor its rendering in the metamutant) and the reachability invariant (every recorded mutant
id has a selector branch) — and live against the DB in the semantic suite.

### Islands: a pin keeps the role of its position

The island sub-contract was built on one sentence — "a `^` pin's interior is ordinary Elixir,
analyzed exactly like top-level Elixir" — which is right about *how* an interior is analyzed and
silent about what its value is *for*. `Fragment.islands/1` was driven by meeting a `^` and threw
the walk's position away, so the structural-position registry, which keeps the literal arms off
the written `field(p, :score)`, said nothing once the same atom sat behind a pin: `^:score` went
to core as unconstrained data and came back `^:mutare`. So did a pinned interval unit
(`ago(^n, ^"day")` → `^"mutare"`, which Ecto rejects when the query is *built*), a pinned cast
type, a binding or select-alias name, and a fragment's `identifier(^name)`. A test comment
recorded the belief behind it: "a pin can only sit at a data position". Ecto accepts a pin at
nearly every position the registry lists.

One guard did carry positional knowledge across the boundary — the pin-side keyword-key rule —
but as a blanket: every island's keyword keys were held, wherever the pin sat, which is why its
doc had to list a known cost (an option list inside a parameter pin was "protected" too).

`islands/2` now reports each pin's **role**, read off the position the walk already threads
(`:structural` where the registry says so, `:value` elsewhere; a pin that *is* the root takes the
role its caller states — `:condition` for a predicate, and `Mutare.Ecto.Subquery`'s for a filter
pair's value and a pinned projection), and `Mutare.Ecto.Island` maps role to what is held. The
keyword-key rule became the `:condition` row, so its known cost no longer reaches a `:value`
pin. Two policies were weighed for the `:structural` row:

  * hold every atom/string literal anywhere in the interior — the keyword-key rule's own
    over-approximation. Rejected: the idiomatic ways to compute a column name put *data*
    literals beside it (`Keyword.get(opts, :sort, :inserted_at)`, `params["sort"]`), and
    `:sort` → `:mutare` — "is the sort option honoured?" — is a live, valid-query mutant this
    would silently lose;
  * hold a literal only where it is **known** to reach the slot: one the interior can evaluate
    to, read through the forms whose value is one of their own sub-expressions. Chosen — it is
    `Fragment`'s `is_nil` stance (prune what is known, emit the rest), and its error is the
    cheap one: a name that reaches the slot *through a call* keeps its sentinel swap, a
    broken-query mutant any test on that path kills, where the first policy's error is a live
    mutant never offered.

Three roles, not one per kind of name: every structural position takes the same policy, so
"field name" versus "interval unit" would be a distinction no code reads. The registry's comments
still say which name each position holds.

### Binding declarations: located by position, read by Ecto's grammar

The host used to find a condition's binding declaration by **searching** the arguments for the
first list it could parse (`BindingList.find/1`), and `BindingList.parse/1` doubled as the
reorder's eligibility test: a non-empty list of `var` / `name: var` / `...`. Ecto's
`escape_bind/1` reads two more entry forms — an interpolated name (`[{^name, p}]`) and an
explicit index (`[{p, 0}, {c, 2}]`) — and a search can only find what it already understands.
So a declaration in either form was invisible: `Host.Condition` fell through to its binding-less
shape and the weave was `dynamic([], p.score > 10)`, an unbound `p` that failed the single build.
"A declaration I cannot read" had silently become "no declaration". The `from` twin did not
degrade at all — `Bindings.declarations/1` handed the unread list to `clean_var/1` and `host/2`
crashed with a `ContractError`.

Three separations fixed it. **Grammar vs. reorderability:** `Mutare.Ecto.Binding.parse/1` is the
entry grammar, mirroring `escape_bind/1` clause for clause and in its order (`{p, c}` is an
indexed positional to Ecto before it is ever a named one); `BindingList.parse/1` admits any list
of such entries, `[]` included; only `transpositions/1` asks what is reorderable (plain
positionals — an indexed entry carries its own position, so transposing it is a no-op).
**Position vs. shape:** both condition macros end `(…, binding \\ [], expr)`, so the call's
effective arity says whether a declaration was written and where; `Host.Condition.locate/3`
reads that slot and reports it *written*, *omitted*, or *uninterpretable*, and
`Host.Bindings` answers `{:ok, declarations} | :error` so the third can never be rendered as
the second. (`find/1` survives for `BindingReorder` alone, where skipping an unread list costs
that reorder its mutants and nothing else.) **Entries vs. nodes:** placement used to tell a
named declaration from a positional one by re-reading the rendered node's shape
(`named?({_, _})`), which an indexed `{p, 0}` would have satisfied; it now works on parsed
entries and renders once.

Two forms are read narrower than Ecto reads them, because the woven `dynamic/2` *re-declares*
the list beside the original, evaluating whatever an entry computes a second time: an index must
be a literal, and an interpolated name a variable or module attribute. `{^next_name(), p}` would
run `next_name/0` twice in the **unmutated** branch. Such a condition is never woven behind a
`dynamic/2`. It was first left unmutated in-fragment, a whole-call delivery judged too rare a
need to carry a second delivery path for; but `Mutare.Ecto.StaticCondition` had meanwhile become
that path (for a subquery in a `having`), so the condition is now rebuilt whole-call there under
the written list, as `Mutare.Ecto.Dynamic` rebuilds a free-standing `dynamic`. To keep each
condition delivered exactly once, the host and the fallback now enumerate the same conditions
(`Host.Condition.from_indices/1`, `locate_on/1`) and split them by one decision,
`StaticCondition.delivery/4` — which is also what brought a standalone `join`'s `on:` into the
fallback. A condition that is itself a `^` pin stays woven under any declaration: its weave is
pin-only and re-declares nothing (`Host.Target`'s root-pin rule), and it keeps reporting its
pin-interior mutants at the condition rather than at the whole call. An `on:` that
`Host.JoinOn` keeps out of the weave stays out of the fallback under any declaration: Ecto's
objection there is to a dynamic, not to the condition, so a rebuild would be valid — but
offering one is a coverage change for every such `on:`, not a consequence of this one.

The same rewrite surfaced a placement bug that corrupted the **baseline**, not just the mutants:
the contiguity rule counted a literal source's joins from the *number of declared entries*, where
a literal source is always exactly one binding, so `[p, q] in Post` (or `[{p, 0}, {q, 0}]`) put
the first join at position 2 instead of 1. The anchor rule is now exact — joins stay contiguous
only behind exactly one positional entry. (The rewrite ran into the unnamed-join miscount too,
fixed on its own in "Bindings: an unnamed join still holds its slot" above; entry-based
placement keeps that section's `_` slot as a parsed positional entry, and a join's named left
side outside the grammar reads as an uninterpretable declaration rather than failing the run.)
