defmodule Mutare.Ecto do
  @moduledoc """
  A mutation-testing plugin for Ecto — a `Mutare.Mutator` that mutates the Ecto
  surface (Repo calls, changeset pipelines, and the query DSL) while respecting
  SQL semantics.

  Enable it with a single configured entry that names your Repo:

      # .mutare.exs
      [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  Listing it both registers the plugin's macro routing (via `c:Mutare.Mutator.macros/0`,
  discovered automatically) and enables its mutations. The `repo:` option arrives as
  `context.opts` in `mutate/2`.

  This module is a thin front for a family of sub-mutators, dispatched by the node it
  sees: `Mutare.Ecto.RepoAggregate`, `Mutare.Ecto.Changeset`, `Mutare.Ecto.Query` (whole-`from`
  mutations), and `Mutare.Ecto.Host` (localized in-fragment `where`/`having` mutations, via the
  SQL catalog in `Mutare.Ecto.Fragment`). All mutations are recorded under the single family name
  `:ecto`. See `DESIGN.md` for the surface map and the SQL-semantics boundary.

  ## Macro routing

  `macros/0` registers the compile-time DSL so Mutare core never splices a runtime selector into
  a query expression (which would poison the single build):

    * `schema`/`embedded_schema` are `:skip`ped — a mutated field name or type is a
      broken schema, not a mutant.
    * the `from` opener and the `where`/`having` family route via the `:routing` classifier
      (`macro_routing/1`), so a binding-referencing condition is delivered through the plugin's
      **selector host** (`host/2` — Ecto's `^`/`dynamic` injection), while plain data is left to
      core. The whole-`from` mutations (clause drop, order-direction flip) ride `mutate/1` over
      the same routed node.
    * the remaining query macros (`order_by`, `select`, `limit`, …) are `:skip`ped pending later
      milestones.

  Resolution of these macros relies on Mutare's `use`-expansion (so the
  `use Ecto.Schema`-injected `import Ecto.Schema`, and a `use MyAppWeb, :live_view`-bundled
  `import Ecto.Query`, are visible) — hence the deployment requirement that Ecto be
  loadable in the Mutare process.
  """

  @behaviour Mutare.Mutator

  alias Mutare.Ecto.{Changeset, Clause, Host, Query, RepoAggregate}

  # Query macros routed through the plugin's **selector host** (`c:Mutare.Mutator.host/2`) — the
  # `from` opener and the standalone/pipe condition macros — via the `:routing` classifier, which
  # decides per call shape whether a position carries a hosted DSL fragment (a binding-referencing
  # `where`/`having` condition) or plain data. See `Mutare.Ecto.Host`.
  @hosted_macros ~w(from where or_where having or_having)a

  # The remaining `Ecto.Query` macros, routed `:skip` so core neither mutates a query expression
  # in place (poison) nor descends a binding/source. A `:skip` node is still offered to `mutate/1`,
  # so the standalone/pipe `order_by`/`limit`/`offset` forms get their ordering/bound mutations
  # there (`Mutare.Ecto.Clause`), exactly as the `from`-keyword forms do (`Mutare.Ecto.Query`).
  # The rest (`select`, `group_by`, `join`, nested `dynamic`, …) stay inert pending later milestones.
  @skipped_macros ~w(
    select select_merge order_by group_by distinct
    limit offset join preload lock with_cte
    windows union union_all except intersect dynamic
  )a

  @impl Mutare.Mutator
  def name, do: :ecto

  @impl Mutare.Mutator
  def macros do
    schema = [
      {Ecto.Schema, :schema, :skip},
      {Ecto.Schema, :embedded_schema, :skip}
    ]

    hosted = for macro <- @hosted_macros, do: {Ecto.Query, macro, :any, :routing}
    skipped = for macro <- @skipped_macros, do: {Ecto.Query, macro, :any, :skip}

    schema ++ hosted ++ skipped
  end

  # Shape-aware routing for the `:routing` query macros — which positions carry a hosted DSL
  # fragment vs. plain data. Delegated to `Mutare.Ecto.Host`.
  @impl Mutare.Mutator
  defdelegate macro_routing(node), to: Host

  # The selector host: per hosted `where`/`having` condition, the `{original, mutants}` pair plus
  # the `dynamic`/`^` `wrap`/`splice` transforms. Delegated to `Mutare.Ecto.Host`.
  @impl Mutare.Mutator
  defdelegate host(node, context), to: Host

  # Whole-node query mutations need no context (no opts, no pipe shape), so they live in
  # `mutate/1`: a `from(...)` node yields its whole-query mutations (`Query`), and a standalone/
  # pipe `order_by`/`limit`/`offset` node yields its ordering/bound mutations (`Clause`). The
  # mutated position is the last argument in both call shapes, so neither needs the pipe mode.
  @impl Mutare.Mutator
  def mutate(node) do
    case Query.mutations(node) ++ Clause.mutations(node) do
      [] -> :skip
      mutations -> mutations
    end
  end

  # Call-shaped mutations need the context (the configured Repo, and the pipe shape that
  # decides where an argument sits): RepoAggregate reads `context.opts[:repo]`, Changeset
  # reads `context.pipe_mode`.
  @impl Mutare.Mutator
  def mutate(node, context) do
    case RepoAggregate.mutations(node, context) ++ Changeset.mutations(node, context) do
      [] -> :skip
      mutations -> mutations
    end
  end
end
