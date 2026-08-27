# Implementation notes & deferred work

A running log of decisions made and limitations discovered while building `mutare_ecto` —
the plugin-side counterpart of core's `../mutare/NOTES.md`. `CLAUDE.md` describes what the
plugin *is*; this file tracks what's intentionally left for later.

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
*which* action. A swapped atom is therefore killable only by asserting the label itself, and the
plugin already commits to the inertness in writing: `RepoWrite`'s `@writes` table fixes `:insert`
for `insert_or_update` *because* "the atom only colours an error changeset's `:action`". The
discriminator against the superficially similar `:on_conflict` swaps: those fork real persistence
behaviour (raise/skip/overwrite) with precise kill conditions; this forks nothing observable.

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
