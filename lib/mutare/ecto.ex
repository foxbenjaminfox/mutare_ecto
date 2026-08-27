defmodule Mutare.Ecto do
  @moduledoc """
  A mutation-testing plugin for Ecto — a `Mutare.Mutator` that mutates the Ecto
  surface (Repo calls, changeset pipelines, and the query DSL) while respecting
  SQL semantics.

  Enable it with a module entry, adding `repo:` when Repo-call mutations are needed:

      # .mutare.exs
      [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  Listing it both registers the plugin's macro routing (via `c:Mutare.MacroRouting.macro_routes/0`,
  discovered automatically) and enables its mutations. Query, changeset, and schema handling do
  not require `repo:`; that option only identifies the module matched by the Repo-call families.

  This module is a thin front for a family of sub-mutators, dispatched by the node it
  sees: `Mutare.Ecto.RepoAggregate` and `Mutare.Ecto.RepoWrite` (Repo calls), `Mutare.Ecto.Changeset`
  (changeset pipelines), `Mutare.Ecto.Query` (whole-`from` mutations), `Mutare.Ecto.Clause` and
  `Mutare.Ecto.QueryTerminal` (standalone/pipe clause macros and `first`/`last`),
  `Mutare.Ecto.BindingReorder` (positional binding transpositions on any binding-list macro),
  `Mutare.Ecto.ClauseDrop` (removing a standalone/pipe clause stage — `q |> where(…)` → `q`),
  `Mutare.Ecto.Dynamic` (in-fragment mutations of a free-standing `dynamic/1,2`, rewritten whole-call
  in place), and `Mutare.Ecto.Host` (localized in-fragment `where`/`having` mutations, via the SQL
  catalog in `Mutare.Ecto.Fragment`).

  ## Configuration

  Each entry takes:

    * `repo:` — the Repo module recognized by `Repo.aggregate` and write-call families. Optional
      when only query/changeset mutations are wanted; without it, Repo-call families are inert.

    * `families:` — narrow the SQL catalog. Accepts `:default` (the unset default — every family
      **except** the opt-in `:string_literal`/`:atom_literal`/`:boolean_literal` arms, which are off
      for safety), `:all` (every family, including those arms), an explicit list, or a
      base-minus-exclusions `{:default | :all, except: [families]}`. Every family is independently
      toggleable; see `families/0` for the full set and `default_families/0` for the default subset.

          # turn the string/atom/boolean literal arms back on
          {Mutare.Ecto, repo: R, families: :all}

          # the easy way to drop a default-on arm
          {Mutare.Ecto, repo: R, families: {:default, except: [:integer_literal]}}

      Even when the string/atom arms are enabled, the structural-position guard in
      `Mutare.Ecto.Fragment` still suppresses a literal at a known DSL form's structural argument
      (the `fragment` template, an interval unit, a cast type). Combined with `:as` (which renames
      the family in the report), `families:` both narrows a run and lets a sub-family be **reported
      under its own name**:

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

  **Structural positions held back from core's families.** Listing the plugin also *suppresses* a
  little noise elsewhere: `argument_marks/1` (`c:Mutare.Mutator.argument_marks/1`) pins the action
  atom of `Ecto.Changeset.apply_action/2` and `apply_action!/2` under core's shared `:structural`
  label, so every value family that honours `:skip_arguments` declines there
  (`Mutare.Mutator.pinned?/1`). The atom is metadata — never consulted on the success path, and on
  the error path it only stamps `changeset.action` — so swapping it mints a mutant killable only by
  asserting the label itself. This is **not** gated by `families:`, which selects what the plugin
  *produces*; the declaration produces nothing and applies whenever the plugin is listed.

  **Equivalence-sensitive families.** Some mutants carry a **report note** — a survivor reads
  `… SURVIVED  — kill may require …` — so it is recognised as honest signal, not a plain test gap.
  Each note names the **specific** data a kill needs, because the equivalence reasons differ:
  `:comparison` is a boundary value (`< vs <=`) or, for `==`/`!=`, a non-NULL row; `:connective`
  (`and`/`or`) is the one genuine three-valued-logic case; `:null_predicate` (`is_nil`/`not is_nil`)
  and `:ordering_nulls` (NULLs placement) both need NULL rows in the column; `:arithmetic` needs an
  operand off the operation's identity (`+`/`-` coincide on a 0 operand, `*`/`/` on ±1);
  `:coalesce` needs a NULL row in the wrapped expression (the drop differs only there); `:temporal`
  needs a row timestamped between the two now-anchored instants; and `:join_type` needs
  an orphan row (an INNER↔LEFT↔RIGHT↔FULL swap only changes the result when a preserved-side row has
  no match, so a mandatory/complete FK makes it legitimately equivalent). The note is attached by
  `finalize/2` (`c:Mutare.Mutator.finalize/2`), which core runs on every produced mutation on both
  delivery paths — so the in-fragment families surface it through the **host** and the
  whole-`from`/clause-macro families (`:ordering_nulls`, `:join_type`) through `mutate/2`.
  `equivalence_sensitive_families/0` returns that set; with the `:as` convention you can
  additionally *group* them under their own report name:

      {Mutare.Ecto, repo: R, families: Mutare.Ecto.equivalence_sensitive_families(), as: :ecto_boundary_null}

  Without a `families:`/`as:` split every mutation is recorded under `:ecto`.

  ## Macro routing

  `macro_routes/0` registers the compile-time DSL so Mutare core never splices a runtime selector
  into a query expression (which would poison the single build):

    * `schema`/`embedded_schema` are `:skip`ped — a mutated field name or type is a
      broken schema, not a mutant.
    * the `from` opener and the `where`/`having` family route via the `:routing` classifier
      (`route_arguments/2`), so a binding-referencing condition is delivered through the plugin's
      **selector host** (`host/2` — Ecto's `^`/`dynamic` injection), while keyword-shorthand data
      is routed to core's literal families (`{:keyword, …}`/`:interpolated`). The whole-`from` mutations
      (clause/bound drop, order/join swaps, select aggregates) ride `mutate/2` over the routed node.
    * the standalone/pipe clause macros (`order_by`, `limit`, `offset`, `select`, `join`, …) also
      route via the `:routing` classifier: their data positions stay raw (so core descends nothing),
      but the **threaded query** (the first argument / the piped left side) is routed `:expression`
      so the upstream query is mutated through the stage (a static `:skip` would suppress it). One
      data position is an exception: a **literal-integer bound** (`limit(q, 10)` / `q |> offset(5)`,
      and the `limit:`/`offset:` keys of the `from` keyword form) routes `:hosted`, so the `:bound`
      ±1 bump is woven **pin-only** (`limit: ^(case …)` — no `dynamic/2`, no bindings) instead of
      duplicating the whole call. Their own `mutate/2` mutations still fire —
      direction/aggregate/scalar (`Mutare.Ecto.Clause`) and **stage removal** (`q |> where(…)` → `q`,
      `Mutare.Ecto.ClauseDrop`). `dynamic` and the
      `is_named_binding` guard helper also register `:skip` (neither is a query-threading stage,
      so core must not descend into their DSL/guard arguments) — but a free-standing `dynamic/1,2`
      is still mutated: core offers the whole call to `mutate/2` (with `context.mutators`, the
      run's enabled specs), where `Mutare.Ecto.Dynamic` rewrites its condition through
      the same SQL catalog a hosted `where`/`having` uses **and** sub-contracts each `^` pin's
      interior to generation over that full set — core's families for the Elixir, this plugin's
      own surface for any Ecto inside it (whole-call offers directly; hosted conditions
      lowered by core's collect to whole-call rebuilds) — all delivered in place (the call sits
      in ordinary expression position, so no host is needed).

  Resolution of these macros relies on Mutare's `use`-expansion (so the
  `use Ecto.Schema`-injected `import Ecto.Schema`, and a `use MyAppWeb, :live_view`-bundled
  `import Ecto.Query`, are visible) — hence the deployment requirement that Ecto be
  loadable in the Mutare process. `required_modules/0` (`c:Mutare.Mutator.required_modules/0`)
  declares that requirement, and core checks it once at startup, before any source is read:
  an external-source run (where the Ecto surface is not on the code path) aborts with a
  `Mutare.EnvironmentError` instead of silently producing incomplete routing.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.Ecto.{
    Aggregate,
    Combination,
    Config,
    Dispatcher,
    Fragment,
    Host,
    Ordering,
    Query,
    Scalar,
    Surface
  }

  # Query macros routed through the plugin's **selector host** (`c:Mutare.Mutator.MacroHost.host/2`) — the
  # `from` opener and the standalone/pipe condition macros — via the `:routing` classifier, which
  # decides per call shape whether a position carries a hosted DSL fragment (a binding-referencing
  # `where`/`having` condition) or plain data. See `Mutare.Ecto.Host`.
  # The composable clause descriptors (`Mutare.Ecto.Surface`) — `order_by`, `limit`,
  # `select`, `join`, … — also route via the `:routing` classifier, for two reasons: (1) it marks
  # the **threaded query** (the first argument / the piped left side) an `:expression`, so core
  # mutates the upstream query through a pipe stage (a static `:skip` would stamp the piped value
  # `:skip` and silently drop every upstream mutation); (2) it keeps their *data* positions raw, so
  # core never descends a binding/expression (poison) — except a literal `limit`/`offset` bound,
  # which routes `:hosted` so its `:bound` bump weaves pin-only through the host. A routed node is
  # still offered to `mutate/2`, where the plugin's own mutators fire: `Mutare.Ecto.Clause`
  # (ordering/aggregate/scalar), `Mutare.Ecto.BindingReorder` (positional binding transpositions),
  # and `Mutare.Ecto.ClauseDrop` (stage removal — `q |> where(…)` → `q`).
  #
  # `dynamic` and `is_named_binding` register `:skip`: neither is a query-threading pipe stage, so
  # core must not descend into their DSL/guard arguments. A `:skip` registration still offers the
  # *whole call* to `mutate/2`, which is how a free-standing `dynamic/1,2` gets its in-fragment
  # mutations (`Mutare.Ecto.Dynamic`, whole-call rewrites delivered in place) and its binding-list
  # reorder — while `is_named_binding` stays entirely inert.
  @impl Mutare.Mutator
  def name, do: :ecto

  @doc "Every SQL family the plugin can emit — the `families: :all` set, for a `families:` subset."
  @spec families() :: [atom()]
  defdelegate families, to: Config, as: :all_families

  @doc """
  The families enabled by default (the `families: :default` / unset set) — every family except the
  opt-in `:string_literal`/`:atom_literal`/`:boolean_literal` arms, which are off for safety until
  explicitly enabled.
  """
  @spec default_families() :: [atom()]
  defdelegate default_families, to: Config

  @doc """
  The families whose survivors may be legitimately unkillable for a data reason, not a test gap —
  `:comparison` (a boundary value, or a non-NULL row for `==`/`!=`), `:connective` (SQL three-valued
  logic), `:null_predicate` and `:ordering_nulls` (NULL rows in the column), `:arithmetic` (an
  operand off the operation's identity — 0 for `+`/`-`, ±1 for `*`/`/`), `:coalesce` (a NULL row in
  the wrapped expression), `:temporal` (a row between the two now-anchored instants), and
  `:join_type` (join
  cardinality — an orphan row). Each carries a report note phrased for its own reason; run them under
  their own `:as` name to group "kill requires …" survivors in the report (see "Configuration").
  """
  @spec equivalence_sensitive_families() :: [atom()]
  defdelegate equivalence_sensitive_families, to: Config

  @doc """
  The `# mutare:ignore` variant vocabulary: every SQL **family** the plugin can emit (`families/0`),
  plus the finer **operator/kind** labels its swap and value families tag — a comparison's operator
  (`<`), a literal's kind (`zero`), an aggregate (`sum`), a sort direction (`asc`), a NULLs placement
  (`nulls_first`), a join kind (`left`), a set operation (`intersect`). Assembled from each producer's
  own labels so the vocabulary can't drift from what is emitted.

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
      Scalar.variant_labels() ++
      Aggregate.variant_labels() ++
      Ordering.variant_labels() ++
      Query.variant_labels() ++
      Combination.variant_labels()
  end

  @doc """
  The declared deployment requirement (`c:Mutare.Mutator.required_modules/0`): the Ecto surface
  the plugin routes (`Ecto.Schema`, `Ecto.Query`) must be loadable in the Mutare process. Core
  checks the declaration **once** at startup — at `Mutare.Mutator.Spec` resolution (before
  `init/1`) — so an external-source run (where Ecto and the target app's modules are not on the
  code path) aborts with a `Mutare.EnvironmentError` instead of silently producing incomplete or
  invalid routing.
  """
  @impl Mutare.Mutator
  def required_modules, do: [Ecto.Schema, Ecto.Query]

  # Structural argument positions on the plain `Ecto.Changeset` call surface, pinned for **core's**
  # value families via the shared `:structural` mark (`c:Mutare.Mutator.argument_marks/1`):
  # `apply_action/2`'s (and the bang twin's) action atom is never consulted on the success path and
  # only stamps `changeset.action` on the error path — metadata, not behaviour — so perturbing it
  # (core's `:atom` family, when enabled alongside) mints a near-equivalent mutant killable only by
  # asserting the label itself. Every `:skip_arguments`-honouring value family declines at the
  # marked position (`Mutare.Mutator.pinned?/1`); the plugin's own dispatch never touches these
  # calls, and `Mutare.Ecto.RepoWrite`'s `:persistence` rewrite fixes the same atom arbitrarily for
  # `insert_or_update` on the same reasoning. Unconditional — `families:` selects what the plugin
  # *produces*; this declaration only suppresses noise elsewhere.
  @impl Mutare.Mutator
  def argument_marks(_config) do
    for fun <- [:apply_action, :apply_action!] do
      {Ecto.Changeset, fun, 2, [1], Mutare.Mutator.structural_label()}
    end
  end

  @impl Mutare.MacroRouting
  def macro_routes do
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
  @impl Mutare.MacroRouting
  defdelegate route_arguments(call, context), to: Host.Routing

  # The host's subscription list: exactly the query macros whose `:routing` classifier can route a
  # position `:hosted` — the `from` opener, the condition macros, `join`, and the bound clause
  # macros (`limit`/`offset`, whose literal value hosts the pin-only `:bound` bump).
  @impl Mutare.Mutator.MacroHost
  def hosted_macros do
    for name <- Surface.hosted_macro_names(), do: {Ecto.Query, name, :any}
  end

  # The selector host: per hosted `where`/`having` condition, the `{original, mutants}` pair plus
  # the `dynamic`/`^` `wrap`/`splice` transforms — and per literal `limit`/`offset` bound, the
  # pin-only bump target (no wrap). Delegated to `Mutare.Ecto.Host`.
  @impl Mutare.Mutator.MacroHost
  defdelegate host(call, context), to: Host

  # Parse the instance's options **once**, at spec resolution (`c:Mutare.Mutator.init/1`): a typo'd
  # option raises at startup next to core's own option validation, and every context-aware callback
  # (`mutate/2`, `host/2`) reads the parsed `%Config{}` back as `context.config` instead of
  # re-parsing `context.opts` per offered node.
  @impl Mutare.Mutator
  def init(opts), do: Config.parse!(opts)

  # Every node mutation runs through `mutate/2` (not `mutate/1`), because all of them read
  # `context.config` — the `dialects:` gate (so a non-portable mutation only fires under a
  # supporting adapter) and, per producer, the `repo:` key. Production is pure: each dispatched
  # tag is wrapped as a `Mutation.tagged(node, [family | finer])` (`Config.tagged/1`) and the
  # `families:` filter + equivalence note are applied once, by core, in `finalize/2`.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # A dispatched result is either the plugin's own `%Mutare.Ecto.Tag{}` — wrapped by
  # `Config.tagged/1` as a `Mutation` carrying its labels, for the `finalize/2` funnel below — or
  # an already-final `%Mutare.Mutator.Mutation{}` relayed with `producer:` set (a sub-contracted
  # island mutant of a free-standing `dynamic`, `Mutare.Ecto.Dynamic`), which `Config.tagged/1`
  # passes through untouched and core's finalize pass bypasses: it is a *core* family's mutant, so
  # the plugin's SQL-family filter and notes never apply to it.
  @impl Mutare.Mutator
  def mutate(node, %{config: %Config{}} = context) do
    case Dispatcher.mutations(node, context) do
      [] -> :skip
      tagged -> Enum.map(tagged, &Config.tagged/1)
    end
  end

  # The tag → filter → enrich funnel, defined once (`Mutare.Ecto.Config.finalize/2`): core applies
  # it to every mutation the plugin produces, on **both** delivery paths — a `mutate/2` return and
  # a host target's `:mutants` — so no delivery site can forget the `families:` filter or the
  # equivalence note. A relayed island mutant (explicit `producer:` — the host's core sub-contract)
  # bypasses it in core: it belongs to the producing core family, whose own funnel already ran.
  @impl Mutare.Mutator
  defdelegate finalize(mutation, context), to: Config
end
