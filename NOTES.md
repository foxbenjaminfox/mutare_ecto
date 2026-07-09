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
