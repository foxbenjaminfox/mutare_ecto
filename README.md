# mutare_ecto

A mutation-testing plugin for [Ecto](https://hexdocs.pm/ecto), built as a custom
[Mutare](../mutare5) mutator. It mutates the Ecto surface an application writes —
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

Early. Implemented today (against Mutare as it stands, no core changes):

- **Schema skip** — `schema`/`embedded_schema` bodies are left untouched.
- **RepoAggregate** — `Repo.aggregate(q, :sum, …)` → `:avg`/`:min`↔`:max`.
- **ChangesetValidationDrop** — drop a `validate_*`/`*_constraint` from a changeset pipeline.
- **Query (whole-`from`)** — drop a `where`/`having` clause; flip an `order_by` direction.

The localized in-DSL query mutations (operator swaps inside `where`, via Ecto's
`^`/`dynamic` injection) depend on Mutare core's *foreign-semantics DSL host*
extensions and land once those do — see `DESIGN.md`, Bucket 3.
