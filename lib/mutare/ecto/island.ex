defmodule Mutare.Ecto.Island do
  @moduledoc false
  # The **interpolation-island seam** — the one home of the sub-contract rule: a `^` pin's
  # interior is ordinary Elixir evaluated at runtime, never the SQL catalog's (an SQL-rationale
  # swap there — `^(min * 2)` → `^(min / 2)` — would mutate the parameter's Elixir value/type), so
  # it is analyzed exactly like top-level Elixir, by core's generation over the run's full spec
  # set. Shared by both condition owners — the selector host (`Mutare.Ecto.Host.Catalog` composes
  # the relayed mutants with the plugin's own SQL catalog as branches of the weave) and the
  # free-standing `dynamic` (`Mutare.Ecto.Dynamic` rebuilds the whole call around each) — and
  # host-specific to neither.
  #
  # `subcontracted/3` runs each pin interior (`Mutare.Ecto.Fragment.islands/1` — collected under
  # the catalog's own descent rules, so no island is reached that the catalog would not have
  # walked past) through `Mutare.Analyze.expression_mutations/3` over the `mutators` of the
  # plugin's `%Mutare.Ecto.Context{}`: the run's **full** enabled spec set, which core threads
  # into both seams this is called from
  # (`host/2` and the whole-call `mutate/2` offer of a registered macro). The full set is what
  # makes the interior ordinary top-level Elixir with no special case:
  #
  #   * core's families own the Elixir — under the user's actual configuration, `:as` renames and
  #     per-instance opts included (a disabled family simply produces nothing);
  #   * this plugin's whole surface participates too: an inner `dynamic(...)` literal is offered
  #     whole-call to `Mutare.Ecto.Dynamic` and mutates once, under SQL semantics — ownership
  #     recurses one pin level at a time (`^` does not nest in Ecto, so the pin is a boundary and
  #     the sub-contract owns everything beneath it);
  #   * an inner `from`/clause macro's hosted conditions are **lowered** by core's collect: each
  #     hosted target mutant comes back as the inner call rebuilt with the mutated condition
  #     spliced `^dynamic`-pinned (the woven selector degenerated to its selected branch), so
  #     hosted delivery never nests while hosted semantics are never lost — hosting is a delivery
  #     optimization, not a semantic category (NOTES "Inner `from` inside a pin interior:
  #     whole-call rewrites only, no condition swaps — RESOLVED (in core)").
  #
  # Each rebuild is relayed as a `Mutare.Mutator.Mutation` with `producer:` set: the Site and its
  # `# mutare:ignore` vocabulary belong to the producing family — core's, or this plugin's —
  # whose own `finalize/2` funnel already ran at generation, so core skips the *relaying*
  # plugin's `finalize/2` for it on both paths (`Mutare.Ecto.Equivalence`), and
  # `Mutare.Ecto.Tag.to_mutation/1` passes it through untouched. No family tagging happens here.
  # **Delivery stays the owner's**, via `subcontracted/3`'s `deliver`: the host relays the
  # condition itself (its weave carries it — the identity default), while `Mutare.Ecto.Dynamic`
  # rebuilds the whole free-standing `dynamic` call around it.
  #
  # A **top-level-pin** condition (`where: ^cond`, `where(q, [u], ^cond)`, a join `on: ^cond`, a
  # `dynamic([p], ^cond)` body) is handled no differently: the SQL catalog is empty for a pin,
  # and `Fragment.islands/1` surfaces the whole interior as one island — so a pinned *Elixir*
  # condition (`^(if params.sort, do: a, else: b)`, `^(rem(n, 2) == 0 and flag)`) has its logic
  # mutated by core exactly as a nested pin's parameter is. A bare `^d` interior is a variable,
  # which core mutates nowhere, so it contributes nothing; the `dynamic` it names is mutated
  # where it is built (`Mutare.Ecto.Dynamic`). The SQL/Elixir boundary is enforced by routing
  # and ownership, not by refusing to look at the pin.

  alias Mutare.Ecto.{Context, Fragment}
  alias Mutare.Mutator.Mutation

  @doc """
  The island sub-contract described in the module header: every relayed, `producer:`-attributed
  mutant of every `^` pin interior in `condition`, each rebuilt into the condition and mapped
  through `deliver` to the node the caller's delivery path emits (the identity default for the
  host's weave; `Mutare.Ecto.Dynamic` rebuilds its whole call).

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
  @spec subcontracted(Macro.t(), Context.t(), (Macro.t() -> Macro.t())) :: [Mutation.t()]
  def subcontracted(condition, %Context{mutators: specs}, deliver \\ & &1) do
    # Core's seam also accepts a callback context, for call-site symmetry with the mutator
    # callbacks, and reads nothing from it — so only the specs cross back into core; the plugin's
    # own struct never does.
    for {interior, rebuild} <- Fragment.islands(condition),
        {spec, mutated, note, variant} <- Mutare.Analyze.expression_mutations(interior, specs),
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

  # The set of keyword-list keys anywhere in `ast` — the key-set the guard in `subcontracted/3`
  # compares.
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
