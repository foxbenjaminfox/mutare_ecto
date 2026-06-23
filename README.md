# mutare_ecto

A mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), built as a custom
[Mutare](../mutare) mutator. It mutates the Ecto surface an application writes —
`Repo` calls, changeset pipelines, and the query DSL — **without treating SQL as
Elixir**: it reuses all of Mutare's plumbing (identity resolution, the
selector/coverage/poison machinery, the delivery host) but ships its own
SQL-semantics mutation catalog.

See [`DESIGN.md`](DESIGN.md) for the full blueprint and the rationale behind that
boundary.

## Usage

Add it (and Mutare) to the app under test, and enable it in `.mutare.exs`:

```elixir
# .mutare.exs
[
  mutators: [
    :all,                              # Mutare's built-ins for ordinary Elixir
    {Mutare.Ecto, repo: MyApp.Repo}    # the Ecto surface
  ]
]
```

`mutare_ecto` requires Ecto and your schemas to be loadable in the Mutare process —
i.e. Mutare run **as a dependency of the app under test**, not against an external
path (so `use Ecto.Schema` expands and the query macros resolve). See *Deployment*
in `DESIGN.md`.

## Status

Milestones 1 and 2 are implemented.

**Bucket 1 + 2 (Milestone 1)** — plain calls and the schema skip, against Mutare's
existing plumbing:

- **Schema skip** — `schema`/`embedded_schema` bodies are left untouched.
- **RepoAggregate** — `Repo.aggregate(q, :sum, …)` → `:avg`/`:min`↔`:max`.
- **ChangesetValidationDrop** — drop a `validate_*`/`*_constraint` from a changeset pipeline.
- **Query (whole-`from`)** — drop a `where`/`having` clause; flip an `order_by` direction.

**Bucket 3 core (Milestone 2)** — the localized, in-fragment query mutations, now
shipping via the selector host:

- **In-`where`/`having` operator swaps** — Comparison (`>`↔`>=`, `<`↔`<=`, `==`↔`!=`),
  Connective (`and`↔`or`), and NullPredicate (`is_nil`↔`not is_nil`), each delivered
  through Ecto's `^`/`dynamic` injection so the metamutant still compiles once and
  selects the active mutant at query-build time. Covers the `from` keyword form
  (`from(u in User, where: u.x == u.y)`) and the composable pipe/direct forms
  (`q |> where([u], …)`, `where(q, [u], …)`), including binding accumulation across
  joins (`dynamic([u, p], …)`). The catalog is the plugin's own SQL-semantics one —
  it reuses none of Mutare's built-in mutators inside a query fragment. See
  `DESIGN.md`, Bucket 3.

This required Mutare core's *foreign-semantics DSL host* extensions (the
mutator-supplied selector host + `:hosted`/`:routing` macro routing); the pinned
[Mutare](../mutare) dependency now carries them.

Still to come (see `DESIGN.md`, Milestones 3–4): the rest of the query catalog
(ordering, bounds, membership, join-type, aggregate-in-select), the keyword-shorthand
shape split, the `nil`-pair exclusion, and SQL-equivalence reporting + dialect gating.
