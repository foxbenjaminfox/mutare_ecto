defmodule Mutare.Ecto do
  @moduledoc """
  A mutation-testing plugin for Ecto — a `Mutare.Mutator` that mutates the Ecto
  surface (Repo calls, changeset pipelines, and the query DSL) while respecting
  SQL semantics.

  Enable it with a module entry, adding `repo:` when Repo-call mutations are needed:

      # .mutare.exs
      [mutators: [:all, {Mutare.Ecto, repo: MyApp.Repo}]]

  Listing it both registers the plugin's macro routing (via `c:Mutare.CallRouting.call_routes/0`,
  discovered automatically) and enables its mutations. Query, changeset, and schema handling do
  not require `repo:`; that option only identifies the module(s) matched by the Repo-call families.

  This module is a thin front for a family of sub-mutators, dispatched by the node it
  sees (`Mutare.Ecto.Dispatcher`): `Mutare.Ecto.RepoAggregate` and `Mutare.Ecto.RepoWrite` (Repo calls), `Mutare.Ecto.Changeset`
  (changeset pipelines), `Mutare.Ecto.Query` (whole-`from` mutations), `Mutare.Ecto.Clause` and
  `Mutare.Ecto.QueryTerminal` (standalone/pipe clause macros and `first`/`last`),
  `Mutare.Ecto.BindingReorder` (positional binding transpositions on any binding-list macro),
  `Mutare.Ecto.ClauseDrop` (removing a standalone/pipe clause stage — `q |> where(…)` → `q`),
  `Mutare.Ecto.Dynamic` (in-fragment mutations of a free-standing `dynamic/1,2`, rewritten whole-call
  in place), and `Mutare.Ecto.Host` (localized in-fragment `where`/`having` mutations, via the SQL
  catalog in `Mutare.Ecto.Fragment`).

  ## Configuration

  Each entry takes:

    * `repo:` — the Repo module recognized by the `Repo.aggregate` and write-call families: one
      module, or a list (`repo: [MyApp.Repo, MyApp.ReplicaRepo]`) when the app has several.
      Optional when only query/changeset mutations are wanted; without it, Repo-call families are
      inert.

    * `families:` — narrow the SQL catalog. Accepts `:default` (the unset default — every family
      **except** the opt-in `:string_literal`/`:atom_literal`/`:boolean_literal` arms, which are off
      for safety), `:all` (every family, including those arms), an explicit list, or a
      base-minus-exclusions `{:default | :all, except: [families]}`. Every family is independently
      toggleable; see `families/0` for the full set and `default_families/0` for the default subset.

          # turn the string/atom/boolean literal arms back on
          {Mutare.Ecto, repo: R, families: :all}

          # the easy way to drop a default-on arm
          {Mutare.Ecto, repo: R, families: {:default, except: [:integer_literal]}}

      Even when the string/atom arms are enabled, a literal at a known DSL form's **structural**
      argument (the `fragment` template, an interval unit, a cast type) is never mutated — see
      `Mutare.Ecto.Fragment`. Combined with `:as` (which renames the family in the report),
      `families:` both narrows a run and lets a sub-family be **reported under its own name**:

          {Mutare.Ecto, repo: R, families: [:comparison], as: :ecto_comparison}

      For a **per-site** subset rather than a run-wide one, each family is also a `# mutare:ignore`
      variant: `# mutare:ignore[ecto:comparison]` suppresses just the comparison mutants on that
      line, the rest still running (see `variants/0`).

    * `dialects:` — gate dialect-specific mutations (default `[]`, the portable core). `:postgres`
      enables `like`↔`ilike`; `:postgres`/`:mysql` enable the `LEFT`↔`RIGHT` join swap (SQLite
      lacks `RIGHT JOIN`).

    * `as:` — rename the recorded family (a core convention; `:as` is consumed by Mutare and never
      reaches the plugin). List the plugin twice with different `families:`/`as:` to split the
      catalog into separately-named report families, or with different `repo:`/`as:` to report
      each repo's mutants under its own name (a single entry with `repo: [A, B]` covers both under
      one name).

  **Structural positions held back from core's families.** Listing the plugin also *suppresses* a
  little noise elsewhere: `call_routes/0` routes the action atom of `Ecto.Changeset.apply_action/2`
  and `apply_action!/2` `:raw`, so no core family ever mutates it — the atom is metadata (it only
  stamps an error changeset's `action`), never behaviour. This is **not** gated by `families:`,
  which selects what the plugin *produces*; the route applies whenever the plugin is listed.

  **Equivalence-sensitive families.** Some mutants carry a **report note** — a survivor reads
  `… SURVIVED  — kill may require …` — so it is recognised as honest signal, not a plain test gap.
  Each note names the **specific** data a kill needs (a boundary row, a non-NULL row, NULL rows in
  a column, an orphan row, …); the set and each family's reason are `Mutare.Ecto.Equivalence`'s,
  and the note is attached by `finalize/2` (`c:Mutare.Mutator.finalize/2`) on every delivery path.
  `equivalence_sensitive_families/0` returns that set; with the `:as` convention you can
  additionally *group* them under their own report name:

      {Mutare.Ecto, repo: R, families: Mutare.Ecto.equivalence_sensitive_families(), as: :ecto_boundary_null}

  Without a `families:`/`as:` split every mutation is recorded under `:ecto`.

  ## Macro routing

  `call_routes/0` registers the compile-time DSL so Mutare core never splices a runtime selector
  into a query expression (which would poison the single build). `schema`/`embedded_schema` are
  routed `:raw` — a mutated field name or type is a broken schema, not a mutant. Every query-building
  macro (`from`, `where`/`having`, `join`, `order_by`, `limit`, …) routes through the per-argument
  classifier `Mutare.Ecto.Host.Routing`, whose `:hosted` positions the selector host
  `Mutare.Ecto.Host` weaves behind Ecto's `^`/`dynamic` injection — a `where`/`having` condition,
  or a literal `limit`/`offset` bound (pin-only — `Mutare.Ecto.Bound`); every routed node is still
  offered whole to `mutate/2` for the in-place families. A free-standing `dynamic/1,2` registers
  `:raw` (its arguments are left as written, the call itself still offered) and is mutated
  whole-call by `Mutare.Ecto.Dynamic`.

  Resolution of these macros relies on Mutare's `use`-expansion (so the
  `use Ecto.Schema`-injected `import Ecto.Schema`, and a `use MyAppWeb, :live_view`-bundled
  `import Ecto.Query`, are visible) — hence the deployment requirement `required_modules/0`
  declares: Ecto must be loadable in the Mutare process.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.CallRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.Ecto.{
    Aggregate,
    Combination,
    Config,
    Context,
    Dispatcher,
    Equivalence,
    Fragment,
    Host,
    Ordering,
    Query,
    Scalar,
    Surface,
    Tag
  }

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
  The families whose survivors may be legitimately unkillable for a data reason, not a test gap
  (see "Equivalence-sensitive families" above; the per-family reasons are `Mutare.Ecto.Equivalence`'s).
  """
  @spec equivalence_sensitive_families() :: [atom()]
  defdelegate equivalence_sensitive_families, to: Equivalence, as: :sensitive_families

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
  # Every producer contributing finer labels (`Mutare.Ecto.Vocabulary`). The arithmetic operators
  # arrive via `Scalar`, which owns them (`Fragment` only applies its swaps per condition node).
  @vocabularies [Fragment, Scalar, Aggregate, Ordering, Query, Combination]
  @impl Mutare.Mutator
  @spec variants() :: [atom() | String.t()]
  def variants do
    labels = Enum.flat_map(@vocabularies, & &1.variant_labels())
    # Producers return their labels raw; the union is canonicalised once, here — see
    # `Mutare.Ecto.Vocabulary`.
    Config.all_families() ++ Enum.sort(Enum.uniq(labels))
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

  @impl Mutare.CallRouting
  def call_routes do
    schema = [
      {Ecto.Schema, :schema, :raw},
      {Ecto.Schema, :embedded_schema, :raw}
    ]

    # The `apply_action`/`apply_action!` action atom, held back from every core family by a `:raw`
    # route on argument 1 (see the moduledoc; the reasoning is NOTES "`apply_action`'s action
    # atom: pinned against core's value families, never mutated"). The changeset itself (argument
    # 0) stays an ordinary expression.
    changeset =
      for fun <- [:apply_action, :apply_action!] do
        {Ecto.Changeset, fun, 2, [:expression, :raw]}
      end

    query =
      Enum.map(Surface.macro_registrations(), fn
        {macro, :routing} -> {Ecto.Query, macro, :any, :routing}
        {macro, :raw} -> {Ecto.Query, macro, :any, :raw}
      end)

    # mutare:ignore[operand_swap] concat order is irrelevant — entries registered as a set
    schema ++ changeset ++ query
  end

  # The per-argument routing classifier — see `Mutare.Ecto.Host.Routing`.
  @impl Mutare.CallRouting
  defdelegate route_arguments(call, context), to: Host.Routing

  # Exactly the macros the classifier can route a position `:hosted`
  # (`Mutare.Ecto.Surface.hosted_macro_names/0`).
  @impl Mutare.Mutator.MacroHost
  def hosted_macros do
    for name <- Surface.hosted_macro_names(), do: {Ecto.Query, name, :any}
  end

  # The selector host: condition weaves and pin-only bound bumps — see `Mutare.Ecto.Host`.
  @impl Mutare.Mutator.MacroHost
  defdelegate host(call, context), to: Host

  # Options are parsed once, at spec resolution, and read back as `context.config` — see
  # `Mutare.Ecto.Config`; each core boundary unpacks that context once into the plugin's
  # `%Mutare.Ecto.Context{}` — see `Mutare.Ecto.Context`.
  @impl Mutare.Mutator
  def init(opts), do: Config.parse!(opts)

  # Every node mutation runs through `mutate/2` (not `mutate/1`), because all of them read
  # `context.config` (the `dialects:` gate and the `repo:` key).
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # Each dispatched `%Mutare.Ecto.Tag{}` becomes a labelled `Mutation` (`Tag.to_mutation/1`) for the
  # `finalize/2` funnel; a `producer:`-relayed island mutant passes through untouched and bypasses
  # the funnel — see `Mutare.Ecto.Island`. The Dispatcher unpacks core's `context` first, and a
  # malformed one fails loudly there (`Context.new/1`).
  @impl Mutare.Mutator
  def mutate(node, context) do
    case Dispatcher.mutations(node, context) do
      [] -> :skip
      tagged -> Enum.map(tagged, &Tag.to_mutation/1)
    end
  end

  # The `families:` filter + equivalence note, applied by core on both delivery paths — see
  # `Mutare.Ecto.Equivalence.finalize/2`, which takes the parsed `%Config{}` unpacked here: the one
  # fact of core's context it needs.
  @impl Mutare.Mutator
  def finalize(mutation, context), do: Equivalence.finalize(mutation, Context.new(context).config)
end
