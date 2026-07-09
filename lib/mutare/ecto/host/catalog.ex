defmodule Mutare.Ecto.Host.Catalog do
  @moduledoc false
  # Produces the logical, enabled alternatives for one hosted SQL condition:
  #
  #   * the plugin's **own** catalogs — the in-fragment operator/literal swaps
  #     (`Mutare.Ecto.Fragment`) and the aggregate swap (`Mutare.Ecto.Aggregate`), each tagged with
  #     its family labels (`Mutare.Ecto.Config.tagged/1`); the `families:` filter and equivalence
  #     note are core's job — `Mutare.Ecto.finalize/2` runs on every host-target mutant, and core
  #     drops a target whose mutants all skip;
  #   * the **sub-contracted** mutants of each interpolation island (`^expr`) — a pin's interior
  #     is ordinary Elixir evaluated at runtime, exactly core's business, so it is handed to
  #     core's generation (`Mutare.Analyze.expression_mutations/3` over `context.mutators`, the
  #     run's enabled non-host specs) and each rebuild is relayed as a
  #     `Mutare.Mutator.Mutation` with `producer:` set — the Site (and its `# mutare:ignore`
  #     vocabulary) belongs to the producing core family, while **delivery stays host-owned**:
  #     the relayed rebuilds are just more branches of the same woven `^`/`dynamic` selector.
  #
  # Besides conditions (`mutants/3`), the catalog also produces the `:bound` ±1 bumps of a
  # literal `limit`/`offset` value (`bounds/1`) — the host weaves them pin-only, no `dynamic/2`.
  #
  # Delivery concerns (`dynamic`, pinning, and splicing) deliberately live in `Mutare.Ecto.Host.Target`.
  # A binding-reorder is *not* hosted: it swaps a written binding list in place (`Mutare.Ecto.BindingReorder`
  # for the standalone/pipe macros, `Mutare.Ecto.Query` for a `from` source list), never the condition body.

  alias Mutare.Ecto.{Aggregate, AST, Config, Fragment}
  alias Mutare.Mutator.Mutation

  @doc """
  The tagged logical mutants for a hosted condition (own catalogs + island sub-contract).

  A **top-level-pin** condition (`where(q, [u], ^cond)`, a join `on: ^cond`) is handled no
  differently: `own` is empty for a pin (the SQL catalogs never mutate a `^`), and `subcontracted`
  surfaces the pin's whole interior as one island and hands it to core — so a pinned *Elixir*
  condition (`^(if params.sort, do: a, else: b)`, `^(rem(n, 2) == 0 and flag)`) has its Elixir
  logic mutated by core, exactly as a nested pin's parameter is. The interior's own nested
  `dynamic(...)`/query fragments stay untouched — core honors their `:skip` routing — so the
  SQL/Elixir boundary is enforced by routing, not by refusing to look at the pin. A bare `^d`
  interior is a variable, which core mutates nowhere, so it contributes nothing of its own.
  """
  @spec mutants(Macro.t(), Config.t(), Mutare.Mutator.context()) :: [Mutare.Mutator.mutation()]
  def mutants(condition, config, context) do
    # The two halves are independent mutant sets (own SQL-catalog swaps vs. sub-contracted pin
    # interiors); concatenation order only affects which arbitrary branch id each ends up under
    # in the woven `^`/`dynamic` selector, never which mutants are produced or how any one branch
    # behaves — equivalent either way.
    # mutare:ignore[operand_swap] equivalent: concatenation order of two independent mutant sets is not observable
    own(condition, config) ++ subcontracted(condition, context)
  end

  @doc """
  The tagged ±1 bumps for a hosted bound value (`limit:`/`offset:`): the off-by-one boundary,
  non-negative only (`Mutare.Ecto.AST.bumps/1`). `[]` unless the value is a literal integer (a
  `^pinned`/expression bound is left raw; its value is mutated where it is bound, in ordinary
  Elixir).
  """
  @spec bounds(Macro.t()) :: [Mutare.Mutator.mutation()]
  def bounds(value) do
    case AST.int_value(value) do
      nil -> []
      n -> for bumped <- AST.bumps(n), do: Config.tagged({:bound, Mutare.AST.literal(bumped)})
    end
  end

  @doc """
  The literal-only bound guard: whether `bounds/1` produces any bump for this value. The routing
  classifier (`Mutare.Ecto.Host.Routing`) routes a bound `:hosted` through this predicate, so
  routing and host are in agreement **by definition** — a value routes `:hosted` exactly when the
  host will weave a bump for it, and there is no second encoding of "literal integer" to drift.
  (`Mutare.Ecto.AST.bumps/1` always yields at least `n + 1`, so non-emptiness is precisely
  literal-integer-ness.)
  """
  @spec bound_literal?(Macro.t()) :: boolean()
  def bound_literal?(value), do: bounds(value) != []

  @doc """
  The plugin's own in-fragment catalogs for a condition — the SQL operator/literal swaps
  (`Mutare.Ecto.Fragment`) and the aggregate swap (`Mutare.Ecto.Aggregate`) — as raw
  `{family, node, label}` tags. The single source of truth for "what the plugin itself mutates in a
  hosted condition", shared by the host (`own/2`, which tags them via `Config.tagged/1`) and
  `Mutare.Ecto.Dynamic` (which rebuilds each into the whole free-standing `dynamic` call). `config`
  threads to `Fragment` only for its `dialects:` gate.
  """
  @spec own_catalog(Macro.t(), Config.t()) :: [{Config.family(), Macro.t(), Fragment.label()}]
  def own_catalog(condition, config) do
    # Same equivalence as `mutants/3` above: two independent catalogs, order not observable.
    # mutare:ignore[operand_swap] equivalent: concatenation order of two independent mutant catalogs is not observable
    Fragment.mutants(condition, config) ++ Aggregate.swaps(condition)
  end

  # Pure production: each catalog tag becomes `Mutation.tagged(node, [family | finer])`.
  defp own(condition, config), do: Enum.map(own_catalog(condition, config), &Config.tagged/1)

  @doc """
  The island sub-contract: `Fragment.islands/1` finds each pin interior under the catalog's own
  descent rules; core generates the interior's mutants under the user's actual configuration
  (`:as` renames and per-instance opts included — a disabled core family simply produces
  nothing), read from `context.mutators` — the run's enabled non-host specs, which core threads
  into both seams this is called from (`host/2` and the whole-call `mutate/2` offer of a
  registered macro). No family tagging here — and the explicit `producer:` makes core skip the
  plugin's `finalize/2` on both paths: the mutant is a *core* family's, with core's note and
  variant, so the plugin's SQL-family filter and equivalence notes don't apply.

  `deliver` maps each rebuilt condition to the node the caller's delivery path emits: the host
  relays the condition itself (its weave carries it — the default identity), while
  `Mutare.Ecto.Dynamic` rebuilds the whole free-standing `dynamic` call around it (its mutants
  are whole-call rewrites through the ordinary in-place selector).

  A **keyword-list key** in the interior is a *field name*, not data — a pinned keyword filter
  (`where(q, ^[active: true])`, or a computed `^(if …, do: [active: true], else: []))`) is Ecto's
  interpolated shorthand, where the key names a column. Core, seeing a bare keyword list, would
  mutate the key (`:active` → `:mutare`, an unknown-field query error) or drop the pair, exactly the
  mutants the non-pinned shorthand routing already skips. So a core mutant that changes the
  interior's **set of keyword keys** is dropped here; a value mutation (which keeps the key-set,
  `[active: false]`) survives, matching the shorthand's "keys raw, values mutated" contract. For a
  non-keyword interior the key-set is empty on both sides, so the guard is a no-op.
  """
  @spec subcontracted(Macro.t(), Mutare.Mutator.context(), (Macro.t() -> Macro.t())) ::
          [Mutation.t()]
  def subcontracted(condition, context, deliver \\ & &1) do
    specs = Map.get(context, :mutators, [])

    for {interior, rebuild} <- Fragment.islands(condition),
        keys = keyword_keys(interior),
        {spec, mutated, note, variant} <-
          Mutare.Analyze.expression_mutations(interior, specs, context),
        keyword_keys(mutated) == keys do
      Mutation.new(deliver.(rebuild.(mutated)), producer: spec, note: note, variant: variant)
    end
  end

  # The set of keyword-list keys anywhere in `ast`. In a query condition a keyword key names a
  # column (`^[field: value]` filter syntax), so a mutant that changes this set has renamed or
  # dropped a field — a broken query, not a live mutant (see `subcontracted/3`).
  defp keyword_keys(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn node, acc ->
        if Mutare.AST.keyword_label?(node),
          do: {node, [Mutare.AST.key_atom(node) | acc]},
          else: {node, acc}
      end)

    MapSet.new(keys)
  end
end
