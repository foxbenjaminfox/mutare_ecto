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

### A binding pattern on a pipe's left (`(p in Post) |> from(…)`) is unsupported

Ecto accepts `(p in Post) |> from(where: p.x > 1)` — `|>` rewrites it to `from(p in Post, …)`
before `from` expands — but the shape is pathological, and neither core nor the plugin can
serve it: core's pipe hoisting binds the left side to `mutare_piped` as a *value*
(`Kernel.in/2` on an unbound `p`), and the plugin's hidden-source `FromCall` (design history
"Piped `from`: the hidden source") declares no bindings for it, so a hosted `where:` would weave
`dynamic([], p.x > 1)`. Either would fail the single build. The plugin cannot guard it —
`Mutare.MacroRouting.Call` carries only the visible arguments, so the left side's shape is
unseen — and core exposing the pipe-left is a core seam (consult before adding). Deferred until
someone writes it: the piped `from` in the wild is a bare or computed queryable on the left
(`Post |> from(as: :post, …)`), whose conditions reference named bindings or are keyword
shorthand, and those are exactly the shapes now covered.

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
narrow what the walk admits). So `Fragment.mutants/2` and `Fragment.islands/1` agree by
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

### Fragment: the coalesce drop is read beneath `is_nil`

`is_nil`'s argument used to be a hard boundary for every family: the walk never entered it, on
two claims — that the value families preserve NULL-ness (true: an arithmetic, aggregate or
literal swap under `is_nil` is provably equivalent), and that the coalesce drop, the one
NULL-ness-changing mutation, could only fire under an `is_nil` the author had written constantly
false. The second assumed a non-NULL default; with a nullable `d` — a column, a pin —
`is_nil(coalesce(u.name, u.role))` is live, and `is_nil(u.name)` differs on every row where
`name` is NULL and `role` is not. The walk still never enters the argument (no island and no
value-family mutant surfaces there — `fragment_descent_test.exs` pins it); the unit's own
`local/3` now reads the argument through a narrowed walk (`Mutare.Ecto.Fragment`'s
`null_interior/1`, the same shape as `exists`'s subquery interior) that offers exactly the
coalesce drop, at every depth, in both polarities.

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
shape and the two spellings yield the same mutants. The hidden source itself routes `:skip`
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
