defmodule Mutare.Ecto do
  @moduledoc """
  A mutation-testing plugin for Ecto — a `Mutare.Mutator` that mutates the Ecto
  surface (Repo calls, changeset pipelines, and the query DSL) while respecting
  SQL semantics.

  Enable it with a module entry, adding `repo:` when Repo-call mutations are needed:

      # .mutare.exs
      [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  Listing it both registers the plugin's macro routing (via `c:Mutare.Mutator.MacroAware.macros/0`,
  discovered automatically) and enables its mutations. Query, changeset, and schema handling do
  not require `repo:`; that option only identifies the module matched by the Repo-call families.

  This module is a thin front for a family of sub-mutators, dispatched by the node it
  sees: `Mutare.Ecto.RepoAggregate` and `Mutare.Ecto.RepoWrite` (Repo calls), `Mutare.Ecto.Changeset`
  (changeset pipelines), `Mutare.Ecto.Query` (whole-`from` mutations), `Mutare.Ecto.Clause` and
  `Mutare.Ecto.QueryTerminal` (standalone/pipe clause macros and `first`/`last`),
  `Mutare.Ecto.BindingReorder` (positional binding transpositions on any binding-list macro),
  `Mutare.Ecto.ClauseDrop` (removing a standalone/pipe clause stage — `q |> where(…)` → `q`), and
  `Mutare.Ecto.Host` (localized in-fragment `where`/`having` mutations, via the SQL catalog in
  `Mutare.Ecto.Fragment`).

  ## Configuration

  Each entry takes:

    * `repo:` — the Repo module recognized by `Repo.aggregate` and write-call families. Optional
      when only query/changeset mutations are wanted; without it, Repo-call families are inert.

    * `families:` — narrow the SQL catalog to a subset (default `:all`). Every family is
      independently toggleable; see `families/0` for the full set. Combined with `:as` (which
      renames the family in the report), this both narrows a run and lets a sub-family be
      **reported under its own name**:

          {Mutare.Ecto, repo: R, families: [:comparison], as: :ecto_comparison}

      For a **per-site** subset rather than a run-wide one, each family is also a `# mutare:ignore`
      variant: `# mutare:ignore[ecto:comparison]` suppresses just the comparison mutants on that
      line, the rest still running (see `variants/0`).

    * `dialects:` — gate dialect-specific mutations (default `[]`, the portable core). `:postgres`
      enables `like`↔`ilike`; `:postgres`/`:mysql` enable the `LEFT`↔`RIGHT` join swap (SQLite
      lacks `RIGHT JOIN`).

    * `as:` — rename the recorded family (a core convention; `:as` is consumed by Mutare and never
      reaches the plugin). List the plugin twice with different `repo:`/`as:` to cover **multiple
      repos**, or with different `families:`/`as:` to split the catalog into separately-named
      report families.

  **Equivalence-sensitive families.** Some mutants carry a **report note** — a survivor reads
  `… SURVIVED  — kill may require …` — so it is recognised as honest signal, not a plain test gap.
  Two equivalence reasons, two notes: `:comparison`, `:connective`, `:null_predicate`, and
  `:ordering_nulls` reason in SQL's three-valued logic (`… kill may require NULL/boundary data`),
  while `:join_type` reasons in join cardinality (`… kill may require an orphan row` — an
  INNER↔LEFT↔RIGHT↔FULL swap only changes the result when a preserved-side row has no match, so a
  mandatory/complete FK makes it legitimately equivalent). The note rides onto the `Mutare.Site` via
  a `%Mutare.Mutator.Mutation{}`, which core accepts on both delivery
  paths — so the in-fragment families surface it through the **host** and the
  whole-`from`/clause-macro families (`:ordering_nulls`, `:join_type`) through `mutate/2`.
  `equivalence_sensitive_families/0` returns that set; with the `:as` convention you can
  additionally *group* them under their own report name:

      {Mutare.Ecto, repo: R, families: Mutare.Ecto.equivalence_sensitive_families(), as: :ecto_boundary_null}

  Without a `families:`/`as:` split every mutation is recorded under `:ecto`.

  ## Macro routing

  `macros/0` registers the compile-time DSL so Mutare core never splices a runtime selector into
  a query expression (which would poison the single build):

    * `schema`/`embedded_schema` are `:skip`ped — a mutated field name or type is a
      broken schema, not a mutant.
    * the `from` opener and the `where`/`having` family route via the `:routing` classifier
      (`macro_routing/1`), so a binding-referencing condition is delivered through the plugin's
      **selector host** (`host/2` — Ecto's `^`/`dynamic` injection), while keyword-shorthand data
      is routed to core's literal families (`{:keyword, …}`/`:pinned`). The whole-`from` mutations
      (clause/bound drop, order/join swaps, select aggregates) ride `mutate/2` over the routed node.
    * the standalone/pipe clause macros (`order_by`, `limit`, `offset`, `select`, `join`, …) also
      route via the `:routing` classifier: their data positions stay raw (so core descends nothing),
      but the **threaded query** (the first argument / the piped left side) is routed `:expression`
      so the upstream query is mutated through the stage (a static `:skip` would suppress it). Their
      own `mutate/2` mutations still fire — direction/bound/aggregate (`Mutare.Ecto.Clause`) and
      **stage removal** (`q |> where(…)` → `q`, `Mutare.Ecto.ClauseDrop`). `dynamic` and the
      `is_named_binding` guard helper stay `:skip` because neither is a query-threading stage.

  Resolution of these macros relies on Mutare's `use`-expansion (so the
  `use Ecto.Schema`-injected `import Ecto.Schema`, and a `use MyAppWeb, :live_view`-bundled
  `import Ecto.Query`, are visible) — hence the deployment requirement that Ecto be
  loadable in the Mutare process.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroAware

  alias Mutare.Ecto.{Aggregate, Config, Dispatcher, Fragment, Host, Ordering, Query, Surface}

  # Query macros routed through the plugin's **selector host** (`c:Mutare.Mutator.MacroAware.host/2`) — the
  # `from` opener and the standalone/pipe condition macros — via the `:routing` classifier, which
  # decides per call shape whether a position carries a hosted DSL fragment (a binding-referencing
  # `where`/`having` condition) or plain data. See `Mutare.Ecto.Host`.
  # The composable clause descriptors (`Mutare.Ecto.Surface`) — `order_by`, `limit`,
  # `select`, `join`, … — also route via the `:routing` classifier, for two reasons: (1) it marks
  # the **threaded query** (the first argument / the piped left side) an `:expression`, so core
  # mutates the upstream query through a pipe stage (a static `:skip` would stamp the piped value
  # `:skip` and silently drop every upstream mutation); (2) it keeps their *data* positions raw, so
  # core never descends a binding/expression (poison). A routed node is still offered to `mutate/2`,
  # where the plugin's own mutators fire: `Mutare.Ecto.Clause` (ordering/bound/aggregate),
  # `Mutare.Ecto.BindingReorder` (positional binding transpositions), and
  # `Mutare.Ecto.ClauseDrop` (stage removal — `q |> where(…)` → `q`).
  #
  # `dynamic` and `is_named_binding` stay `:skip`: neither is a query-threading pipe stage, so core
  # must not descend into their DSL/guard arguments.
  @impl Mutare.Mutator
  def name, do: :ecto

  @doc "Every SQL family the plugin can emit — the `families: :all` set, for a `families:` subset."
  @spec families() :: [atom()]
  defdelegate families, to: Config, as: :all_families

  @doc """
  The families whose survivors may be legitimately unkillable for a data reason, not a test gap —
  `:comparison`, `:connective`, `:null_predicate`, `:ordering_nulls` (SQL's three-valued logic) and
  `:join_type` (join cardinality — an orphan row). Each carries a report note; run them under their
  own `:as` name to group "kill requires …" survivors in the report (see "Configuration").
  """
  @spec equivalence_sensitive_families() :: [atom()]
  defdelegate equivalence_sensitive_families, to: Config

  @doc """
  The `# mutare:ignore` variant vocabulary: every SQL **family** the plugin can emit (`families/0`),
  plus the finer **operator/kind** labels its swap and value families tag — a comparison's operator
  (`<`), a literal's kind (`zero`), an aggregate (`sum`), a sort direction (`asc`), a NULLs placement
  (`nulls_first`), a join kind (`left`). Assembled from each producer's own labels so the vocabulary
  can't drift from what is emitted.

  Every recorded mutant carries its family label and, for a swap/value family, the finer label too —
  so a qualified directive suppresses **either** the whole family or one operator at a site, the rest
  still running. The per-site analogue of the run-wide `families:` filter, only finer. With the
  default config every mutant is recorded under `:ecto`, so a directive reads
  `# mutare:ignore[ecto:comparison]` or `# mutare:ignore[ecto:<]`; an `:as`-renamed run reads
  `# mutare:ignore[<as>:<label>]` (the vocabulary is unchanged). A **bare** `# mutare:ignore[ecto]`
  still suppresses every mutant at the site.

      from(u in User, where: u.age > 18 and u.height < 90) # mutare:ignore[ecto:<]
      #                                            ^ only the `<` swap is suppressed; the `>` swap,
      #                                              and the 18/90 literal swaps, all keep running
  """
  @impl Mutare.Mutator
  @spec variants() :: [atom() | String.t()]
  def variants do
    Config.all_families() ++
      Fragment.variant_labels() ++
      Aggregate.variant_labels() ++
      Ordering.variant_labels() ++
      Query.variant_labels()
  end

  @impl Mutare.Mutator.MacroAware
  def macros do
    schema = [
      {Ecto.Schema, :schema, :skip},
      {Ecto.Schema, :embedded_schema, :skip}
    ]

    query =
      Enum.map(Surface.macro_registrations(), fn
        {macro, :routing} -> {Ecto.Query, macro, :any, :routing}
        {macro, :skip} -> {Ecto.Query, macro, :any, :skip}
      end)

    # mutare:ignore[operand_swap] concat order is irrelevant — entries registered as a set
    schema ++ query
  end

  # Shape-aware routing for the `:routing` query macros — which positions carry a hosted DSL
  # fragment vs. plain data. Delegated to `Mutare.Ecto.Host.Routing` (the classifier half of the host).
  @impl Mutare.Mutator.MacroAware
  defdelegate macro_routing(node), to: Host.Routing

  # The selector host: per hosted `where`/`having` condition, the `{original, mutants}` pair plus
  # the `dynamic`/`^` `wrap`/`splice` transforms. Delegated to `Mutare.Ecto.Host`.
  @impl Mutare.Mutator.MacroAware
  defdelegate host(node, context), to: Host

  # Every node mutation runs through `mutate/2` (not `mutate/1`), because all of them now read
  # `context.opts` — the `families:` filter (every family is independently toggleable) and the
  # `dialects:` gate (so a non-portable mutation only fires under a supporting adapter).
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def mutate(node, %{opts: opts} = context) do
    config = Config.parse!(opts)
    context = Map.put(context, :ecto_config, config)
    tagged = Dispatcher.mutations(node, context)

    case for tag <- tagged,
             {family, mutated, finer} = Config.split_tag(tag),
             Config.family_enabled?(config, family),
             do: Config.enrich(family, mutated, finer) do
      [] -> :skip
      mutations -> mutations
    end
  end
end
