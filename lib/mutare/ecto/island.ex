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
  # `subcontracted/3` runs each pin interior (`Mutare.Ecto.Fragment.islands/2` — collected under
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
  # `dynamic([p], ^cond)` body) is *analyzed* no differently (its **delivery** by the host does
  # differ — pin-only, so Ecto still dispatches on the interpolated value; the root-pin rule,
  # `Mutare.Ecto.Host.Target`): the SQL catalog is empty for a pin,
  # and `Fragment.islands/2` surfaces the whole interior as one island — so a pinned *Elixir*
  # condition (`^(if params.sort, do: a, else: b)`, `^(rem(n, 2) == 0 and flag)`) has its logic
  # mutated by core exactly as a nested pin's parameter is. A bare `^d` interior is a variable,
  # which core mutates nowhere, so it contributes nothing; the `dynamic` it names is mutated
  # where it is built (`Mutare.Ecto.Dynamic`). The SQL/Elixir boundary is enforced by routing
  # and ownership, not by refusing to look at the pin.
  #
  # "Exactly like top-level Elixir" says **how** an interior is analyzed, not what its value is
  # for: a pin moves a value out of the SQL, never out of the position it fills, and
  # `field(p, ^:score)` names a column as surely as `field(p, :score)` does. So
  # `Fragment.islands/2` reports each pin's **role**, and this seam is the home of the **role
  # policy** (`subcontracted/3`): which written literals of an interior are still query
  # structure, and so not core's to rewrite.

  alias Mutare.Ecto.{AST, Context, Fragment}
  alias Mutare.Mutator.Mutation

  @doc """
  The island sub-contract described in the module header: every relayed, `producer:`-attributed
  mutant of every `^` pin interior in `condition`, each rebuilt into the condition and mapped
  through `deliver` to the node the caller's delivery path emits (the identity default for the
  host's weave; `Mutare.Ecto.Dynamic` rebuilds its whole call).

  ## The role policy

  Core is handed an *interior*, and an interior cannot show what its value is for: `:score` is
  a status to compare with in `p.status == ^:score` and a column name in `field(p, ^:score)`.
  Where the pin sits says which — **positional knowledge only this seam has** — so each island
  arrives with its role (`t:Mutare.Ecto.Fragment.role/0`), and the role selects the written
  literals of the interior that are **held**: structure, not data. A relayed mutant that
  changes the held set is a broken query rather than a mutant — the very ones the written form
  never offers — and is dropped; every other mutant of the interior is core's, as anywhere:

    * `:value` — nothing is held: the interior is a parameter, plain application data.
    * `:condition` — the interior's **keyword keys** are held (the keyword-key rule, below).
    * `:structural` — the literals the interior can **evaluate to** are held (the name rule,
      below).

  The policy reads the relaying producer too. It guards against a producer that treats query
  structure as plain Elixir data, so it must not reject mutants this plugin produced while
  analyzing the island's nested Ecto surface: an inner
  `dynamic(... exists(from(..., where: ..., select: ...)))` legitimately drops a subquery
  filter by removing the `where:` clause key from the inner `from` — a valid SQL mutant, not
  a renamed pinned filter field.

  ### `:condition` — the keyword-key rule's second application

  A **keyword-list key** in a condition position names a **column**, never data. That rule is
  stated once for the written shorthand — `Mutare.Ecto.Host.Routing` routes a
  `where(q, active: true)` pair's *key* raw and only its value `:interpolated` — and applied a
  second time here, at the only other boundary where a condition-position keyword list can
  appear: a pin that *is* the condition (`where(q, ^[active: true])`, or a *computed*
  `^(if …, do: [active: true], else: [])`). This second application cannot ride dispatch: a
  bare `[active: true]` — let alone one built by arbitrary Elixir — has no call shape for any
  recognizer to classify as a filter. So a mutant that changes the interior's **set of keyword
  keys** has renamed or dropped a field (an unknown-field query error, exactly the mutants the
  shorthand routing skips) and is dropped; a value mutation (which keeps the key-set,
  `[active: false]`) survives, matching the shorthand's "keys raw, values mutated" contract.

  The keys are read anywhere in the interior, an over-approximation with a known cost: a
  keyword key that *is* plain data — an option list built inside the pinned condition, say —
  is held too, so a core mutant that renames or deletes such a pair (e.g. `:keyword_delete`)
  is dropped along with the field renames. The cost stops at this role: Ecto reads a keyword
  list as a filter only where the pin is the whole condition, so an option list inside a
  `:value` pin (`p.score > ^lookup(n, scope: :all)`) is core's, as at top level.

  ### `:structural` — a literal that is the name

  A pin at a structural position (`Mutare.Ecto.Fragment`'s registry: `field(p, ^name)`,
  `type(^v, ^type)`, `ago(^n, ^unit)`, `as(^binding)`, `selected_as(^alias)`, a fragment's
  `identifier(^name)`) computes the column, cast type, unit or name the written literal would
  have been. The registry keeps the plugin's literal arms off the written `:score`; it would be
  idle if core's atom family renamed the pinned one (`field(p, ^:mutare)` — an unknown-column
  query on every run of the mutant).

  But a pin also admits *computing* the name, and that logic is ordinary Elixir:
  `^(if asc, do: :score, else: :views)` with its condition negated sorts by the other, valid
  column — a live mutant. So the role holds a literal only where it is **known** to reach the
  slot: a literal the interior can evaluate *to*, read through the forms whose value is one of
  their own written sub-expressions — the literal itself (an atom, a string, a module alias),
  a written list's or tuple's elements (`{:array, :string}`, a pinned `select`'s field list),
  a block's last expression, either operand of `||`, a branch of an `if`/`unless`/`case`/`cond`.
  Everything else — a condition, a lookup key, a call's arguments — is not known to be the
  name, and an unknown is never held (the stance of `Mutare.Ecto.Fragment`'s `is_nil` rule:
  prune what is known, emit the rest).

  Known cost, on that side: a literal that reaches the slot *through a call* —
  `Keyword.get(opts, :sort, :inserted_at)`'s default — is not known to, so its sentinel swap is
  emitted: an unknown-column query on the path that takes the default, which any test running
  that path kills.
  """
  @spec subcontracted(Macro.t(), Context.t(), (Macro.t() -> Macro.t())) :: [Mutation.t()]
  def subcontracted(condition, %Context{mutators: specs}, deliver \\ & &1) do
    # Core's seam also accepts a callback context, for call-site symmetry with the mutator
    # callbacks, and reads nothing from it — so only the specs cross back into core; the plugin's
    # own struct never does.
    for {interior, role, rebuild} <- Fragment.islands(condition, :condition),
        {spec, mutated, note, variant} <- Mutare.Analyze.expression_mutations(interior, specs),
        structure_kept?(spec, role, interior, mutated) do
      Mutation.new(deliver.(rebuild.(mutated)), producer: spec, note: note, variant: variant)
    end
  end

  # The plugin's own relayed mutants have already been produced under Ecto's SQL catalog. Their
  # keyword key changes are Ecto query-shape mutations (for example an inner `where:` clause
  # drop), not core's view of a pinned keyword filter as ordinary Elixir data. The bypass is
  # deliberately **self-only** (matched by this plugin's module, `:as` renames included): any
  # other producer — a core family or a third-party mutator — reasons in Elixir's semantics,
  # where treating structure as data is exactly the hazard being guarded.
  defp structure_kept?(%Mutare.Mutator.Spec{module: Mutare.Ecto}, _role, _original, _mutated),
    do: true

  defp structure_kept?(_spec, role, original, mutated),
    do: held(role, mutated) == held(role, original)

  # The role policy (`subcontracted/3`'s doc): the written literals of `interior` that are
  # structure under `role`, as the set the guard compares. A role with no clause here has no
  # policy, and crashes rather than pass as plain data.
  defp held(:value, _interior), do: MapSet.new()
  defp held(:condition, interior), do: keyword_keys(interior)
  defp held(:structural, interior), do: interior |> result_literals() |> MapSet.new()

  # The keyword-list keys anywhere in `ast`.
  defp keyword_keys(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn node, acc ->
        if Mutare.AST.keyword_label?(node),
          do: {node, [Mutare.AST.key_atom(node) | acc]},
          else: {node, acc}
      end)

    MapSet.new(keys)
  end

  # The name rule's reader (`subcontracted/3`'s doc): the written literals `ast` can evaluate
  # **to**, one clause per form the rule lists. Every other form — a variable, a call and its
  # arguments, an interpolated string — computes its value by means this reader does not know,
  # and yields nothing.
  defp result_literals({:__block__, _meta, [literal]})
       when is_atom(literal) or is_binary(literal),
       do: [literal]

  defp result_literals({:__aliases__, _meta, _segments} = module),
    do: [Sourceror.strip_meta(module)]

  defp result_literals({:__block__, _meta, [elements]}) when is_list(elements),
    do: Enum.flat_map(elements, &result_literals/1)

  defp result_literals({:__block__, _meta, [{left, right}]}),
    do: result_literals(left) ++ result_literals(right)

  defp result_literals({:__block__, _meta, [_, _ | _] = statements}),
    do: statements |> List.last() |> result_literals()

  defp result_literals({:{}, _meta, elements}), do: Enum.flat_map(elements, &result_literals/1)
  defp result_literals({left, right}), do: result_literals(left) ++ result_literals(right)

  defp result_literals({:||, _meta, [left, right]}),
    do: result_literals(left) ++ result_literals(right)

  defp result_literals({branching, _meta, [_ | _] = args})
       when branching in [:if, :unless, :case, :cond] do
    for {_do_or_else, body} <- AST.unwrap_list(List.last(args)) || [],
        literal <- branch_literals(body),
        do: literal
  end

  defp result_literals(_computed), do: []

  # A `do`/`else` body: the `->` clauses of a `case`/`cond` (each clause's right side), or the
  # one expression of an `if`/`unless`.
  defp branch_literals(clauses) when is_list(clauses),
    do: for({:->, _meta, [_head, body]} <- clauses, literal <- result_literals(body), do: literal)

  defp branch_literals(body), do: result_literals(body)
end
