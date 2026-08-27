defmodule Mutare.Ecto.Island do
  @moduledoc false
  # The **interpolation-island seam**: the sub-contracted mutants of each `^expr` interior of a
  # condition. Shared by both condition owners — the selector host (`Mutare.Ecto.Host.Catalog`
  # composes them with the plugin's own SQL catalogs as branches of the weave) and the
  # free-standing `dynamic` (`Mutare.Ecto.Dynamic` rebuilds the whole call around each) — and
  # host-specific to neither: a pin's interior is ordinary Elixir evaluated at runtime, analyzed
  # exactly like top-level Elixir. It is handed to core's generation
  # (`Mutare.Analyze.expression_mutations/3` over `context.mutators`, the run's **full** spec set —
  # this plugin included through its ordinary `mutate/2` surface, so an inner `dynamic(...)`
  # literal buried in the pin is offered whole-call to `Mutare.Ecto.Dynamic` and mutates under SQL
  # semantics, while the surrounding Elixir stays core's). Each rebuild is relayed as a
  # `Mutare.Mutator.Mutation` with `producer:` set — the Site (and its `# mutare:ignore`
  # vocabulary) belongs to the producing family, core's or this plugin's, whose own `finalize/2`
  # funnel already ran at generation — while **delivery stays the owner's**: the host's woven
  # `^`/`dynamic` selector, or `Dynamic`'s whole-call in-place rewrite (`subcontracted/3`'s
  # `deliver`).
  #
  # The seam is also the only place the pin-side half of the "a keyword key in a condition
  # position names a column" rule can be applied (`subcontracted/3`'s key-set guard): that a
  # pin's value will be spliced as a condition is positional knowledge no call-shape recognizer
  # has.

  alias Mutare.Ecto.Fragment
  alias Mutare.Mutator.Mutation

  @doc """
  The island sub-contract: `Fragment.islands/1` finds each pin interior under the catalog's own
  descent rules; the interior's mutants are generated under the user's actual configuration
  (`:as` renames and per-instance opts included — a disabled family simply produces nothing),
  read from `context.mutators` — the run's **full** enabled spec set, which core threads into
  both seams this is called from (`host/2` and the whole-call `mutate/2` offer of a registered
  macro). The full set is what makes the interior *ordinary top-level Elixir* with no special
  case: core's families own the Elixir, and this plugin's whole surface participates too — an
  inner `dynamic(...)` literal is offered whole-call to `Mutare.Ecto.Dynamic`, and an inner
  `from`/clause macro's hosted conditions are **lowered** by core's collect (each hosted target
  mutant comes back as the inner call rebuilt with the mutated condition spliced
  `^dynamic`-pinned — the woven selector degenerated to its selected branch — so hosted
  delivery never nests while hosted semantics are never lost). No family tagging here — and
  the explicit `producer:` makes core skip the *relaying*
  `finalize/2` on both paths: each mutant's own producer funnel (a core family's, or this
  plugin's `families:` filter + equivalence note) already ran at generation, inside the seam.

  `deliver` maps each rebuilt condition to the node the caller's delivery path emits: the host
  relays the condition itself (its weave carries it — the default identity), while
  `Mutare.Ecto.Dynamic` rebuilds the whole free-standing `dynamic` call around it (its mutants
  are whole-call rewrites through the ordinary in-place selector).

  A **top-level-pin** condition (`where(q, [u], ^cond)`, a join `on: ^cond`, a
  `dynamic([p], ^cond)` body) is handled no differently: `Fragment.islands/1` surfaces the pin's
  whole interior as one island, so a pinned *Elixir* condition
  (`^(if params.sort, do: a, else: b)`, `^(rem(n, 2) == 0 and flag)`) has its Elixir logic
  mutated by core, exactly as a nested pin's parameter is. A bare `^d` interior is a variable,
  which core mutates nowhere, so it contributes nothing of its own.

  ## The keyword-key rule's second application

  A **keyword-list key** in a condition position names a **column**, never data. That rule is
  stated once for the written shorthand — `Mutare.Ecto.Host.Routing` routes a
  `where(q, active: true)` pair's *key* raw and only its value `:interpolated` — and applied a
  second time here, at the only other boundary where a condition-position keyword list can
  appear: inside a pin (`where(q, ^[active: true])`, or a *computed*
  `^(if …, do: [active: true], else: [])`). This second application cannot ride dispatch: a
  bare `[active: true]` — let alone one built by arbitrary Elixir — has no call shape for any
  recognizer to classify as a filter; the fact that this value will be spliced as a condition
  is **positional knowledge only this seam has**. So the seam applies it as a guard: a mutant
  that changes the interior's **set of keyword keys** has renamed or dropped a field (an
  unknown-field query error, exactly the mutants the shorthand routing skips) and is dropped;
  a value mutation (which keeps the key-set, `[active: false]`) survives, matching the
  shorthand's "keys raw, values mutated" contract. For a non-keyword interior the key-set is
  empty on both sides, so the guard is a no-op.

  The guard is a protection against core treating a condition-position keyword filter as plain
  Elixir data. It must not reject mutants produced by this plugin while analyzing the island's
  nested Ecto surface: an inner `dynamic(... exists(from(..., where: ..., select: ...)))`
  legitimately drops a subquery filter by removing the `where:` clause key from the inner
  `from`, and that is a valid SQL mutant rather than a renamed pinned filter field.

  Known cost of the over-approximation, on the guarded (non-Ecto-producer) branch: a keyword
  key that *is* plain data — an option list built inside the pin, say — is protected too, so a
  core mutant that renames or deletes such a pair (e.g. `:keyword_delete`) is dropped along
  with the field renames.
  """
  @spec subcontracted(Macro.t(), Mutare.Mutator.context(), (Macro.t() -> Macro.t())) ::
          [Mutation.t()]
  def subcontracted(condition, context, deliver \\ & &1) do
    specs = Map.get(context, :mutators, [])

    for {interior, rebuild} <- Fragment.islands(condition),
        {spec, mutated, note, variant} <-
          Mutare.Analyze.expression_mutations(interior, specs, context),
        keyword_filter_keys_preserved?(spec, interior, mutated) do
      Mutation.new(deliver.(rebuild.(mutated)), producer: spec, note: note, variant: variant)
    end
  end

  # The plugin's own relayed mutants have already been produced under Ecto's SQL catalog. Their
  # keyword key changes are Ecto query-shape mutations (for example an inner `where:` clause
  # drop), not core's view of a pinned keyword filter as ordinary Elixir data. The bypass is
  # deliberately **self-only** (matched by this plugin's module, `:as` renames included): any
  # other producer — a core family or a third-party mutator — reasons in Elixir's semantics,
  # where the column-rename hazard is exactly the one being guarded.
  defp keyword_filter_keys_preserved?(
         %Mutare.Mutator.Spec{module: Mutare.Ecto},
         _original,
         _mutated
       ),
       do: true

  defp keyword_filter_keys_preserved?(_spec, original, mutated),
    do: keyword_keys(mutated) == keyword_keys(original)

  # The set of keyword-list keys anywhere in `ast`. For core-produced island mutants in a query
  # condition, a keyword key may name a column (`^[field: value]` filter syntax), so a mutant that
  # changes this set can have renamed or dropped a field — a broken query, not a live mutant (see
  # `subcontracted/3`).
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
