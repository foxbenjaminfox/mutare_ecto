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

All four milestones are implemented: the Repo/changeset/schema surface (1), the selector
host (2), the full query catalog (3), and configuration — `families:`, `dialects:`, multi-repo,
per-family naming, and equivalence reporting (4).

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

**Full query catalog (Milestone 3, in progress)** — more of the SQL catalog, landing in
the two existing delivery paths (no new core machinery):

- **Membership** — in a `where`/`having` fragment, `x in ^list` ↔ `x not in ^list`
  (polarity) and `like` ↔ `ilike` (case-sensitivity), delivered through the selector host.
- **FragmentLiteral** — a non-pinned integer literal *written into* a fragment
  (`u.age > 18` → `19`/`17`/`0`): the library owns these because they are part of the SQL
  the query runs, not interpolated Elixir, so core never sees them. Boundary `±1` plus the
  zero sentinel, deduped.
- **Bound** — drop a `limit`/`offset` clause, and bump its literal value by `±1`
  (non-negative only). Both the whole-`from` keyword form and the standalone/pipe form
  (`limit(q, 10)`, `q |> offset(5)`).
- **JoinType** — whole-`from`: swap a join's kind by rewriting its clause key,
  `join`/`inner_join` ↔ `left_join` (the portable `INNER`/`LEFT` pair;
  `RIGHT`/`FULL`/`CROSS` are dialect-gated in Milestone 4).
- **Ordering (standalone/pipe)** — flip a sort direction in the composable form too
  (`order_by(q, [u], asc: u.name)`, `q |> order_by(desc: u.name)`), alongside the
  whole-`from` `order_by` flip already shipped. The `limit`/`offset`/`order_by`/`select`
  standalone forms all ride `mutate/1` over the (otherwise `:skip`ped) macro node — no host
  needed, since the call is itself an expression the in-place selector can wrap whole.
- **Aggregate (in `select`)** — swap an aggregate (`sum`↔`avg`, `min`↔`max`) wherever it
  appears in a `select`/`select_merge` expression — a bare call, or one nested in a map,
  tuple, or keyword list. Both the whole-`from` keyword form and the standalone/pipe form.
  (`count` is left alone, as in `RepoAggregate`.)
- **Binding-reorder** — in a multi-binding `where`/`having`, swap two binding references
  (`a.x == b.y` → `b.x == a.y`). Reordering the declared binding list is equivalent to
  swapping the body's references, so it rides the host with no special delivery path; emitted
  only when both bindings actually appear in the condition.

- **Keyword-shorthand split** — `where(q, category: "Foo")` and the bindingless
  `from(S, where: [category: "Foo"])` carry *data* values, so they're mutated by core's literal
  families (recorded under `:literal`/`:string`, not `:ecto`) while the column-name keys and
  `nil`/compound pairs are left raw. Delivered `^`-pinned, since Ecto rejects a bare selector
  `case` in a query value position. This required two new Mutare core extensions — *per-keyword-pair
  routing* (`{:keyword, value_treatments}`) and *pinned in-place delivery* (`:pinned`), the
  successors to the Milestone-2 host/`:routing` extensions; the pinned [Mutare](../mutare)
  dependency now carries them. (A shorthand clause *mixed into a binding* `from` stays `:hosted`
  and isn't split — a documented edge; see `DESIGN.md`.)

**Configuration (Milestone 4)** — each `{Mutare.Ecto, …}` entry is tunable:

- **`families:`** — narrow the SQL catalog to a subset (default `:all`); every family
  (`:comparison`, `:null_predicate`, `:bound`, …) is independently toggleable. An unknown family
  name fails loudly. See `Mutare.Ecto.families/0`.
- **`dialects:`** — gate dialect-specific mutations (default `[]`, the portable core): `:postgres`
  enables `like`↔`ilike`; `:postgres`/`:mysql` enable the `LEFT`↔`RIGHT` join swap (SQLite lacks
  `RIGHT JOIN`).
- **Per-family naming + multiple repos** — list the plugin more than once with different
  `families:`/`as:` (to report a sub-family under its own name) or `repo:`/`as:` (to cover several
  repos); `:as` renames the recorded family.
- **Equivalence reporting** — mutants of the families whose survivors may be legitimately
  unkillable without a `NULL`/boundary fixture (`:comparison`, `:connective`, `:null_predicate` —
  SQL's three-valued logic) carry a **report note**: a survivor reads
  `… SURVIVED  — kill may require NULL/boundary data` (and the JSON report's `description`), so it's
  not mistaken for a plain test gap. This rides a Mutare core `Site` note threaded from the host.
  `Mutare.Ecto.equivalence_sensitive_families/0` plus the `:as` convention additionally lets you
  *group* them under their own report name. (The catalog is SQL-native, so it emits no
  Elixir-equivalent mutations to inflate the denominator in the first place.)

      # .mutare.exs — split the boundary/NULL families out under their own report name
      [
        mutators: [
          :all,
          {Mutare.Ecto, repo: MyApp.Repo, dialects: [:postgres],
           families: Mutare.Ecto.equivalence_sensitive_families(), as: :ecto_boundary_null},
          {Mutare.Ecto, repo: MyApp.Repo, dialects: [:postgres]}
        ]
      ]
