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
  sees: `Mutare.Ecto.RepoAggregate`, `Mutare.Ecto.Changeset`, and `Mutare.Ecto.Query`.
  All mutations are recorded under the single family name `:ecto`. See `DESIGN.md` for
  the surface map and the SQL-semantics boundary.

  ## Macro routing

  `macros/0` registers the compile-time DSL so Mutare core leaves it alone:

    * `schema`/`embedded_schema` are `:skip`ped — a mutated field name or type is a
      broken schema, not a mutant.
    * the query macros (`from`, `where`, `order_by`, …) are `:skip`ped so core never
      tries to splice a runtime selector into a query expression (which would poison
      the single build). The plugin mutates them itself, with DSL knowledge.

  Resolution of these macros relies on Mutare's `use`-expansion (so the
  `use Ecto.Schema`-injected `import Ecto.Schema`, and a `use MyAppWeb, :live_view`-bundled
  `import Ecto.Query`, are visible) — hence the deployment requirement that Ecto be
  loadable in the Mutare process.
  """

  @behaviour Mutare.Mutator

  alias Mutare.Ecto.{Changeset, Query, RepoAggregate}

  # The `Ecto.Query` macros whose arguments are query expressions (or bindings), all
  # routed `:skip` so core neither mutates a query condition in place (poison) nor a
  # binding/source. The plugin's own `mutate/*` reaches the ones it can mutate safely.
  @query_macros ~w(
    from where or_where having or_having
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

    queries = for macro <- @query_macros, do: {Ecto.Query, macro, :any, :skip}

    schema ++ queries
  end

  # Whole-node query mutations need no context (no opts, no pipe shape), so they live
  # in `mutate/1`: a `from(...)` node yields where/having drops and order-direction flips.
  @impl Mutare.Mutator
  def mutate(node) do
    case Query.mutations(node) do
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
