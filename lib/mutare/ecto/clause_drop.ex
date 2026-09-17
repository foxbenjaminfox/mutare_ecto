defmodule Mutare.Ecto.ClauseDrop do
  @moduledoc """
  Drop a standalone/pipe **query clause** — the composable counterpart of `Mutare.Ecto.Query`'s
  whole-`from` clause drop, analogous to `Mutare.Ecto.Changeset`'s validator drop.
  Where `Query` removes a `where:`/`limit:` clause from a `from(…)` keyword list, this removes the
  same kinds of clause written as a standalone call or pipe stage:

      q |> where([u], u.active)   →  q          "is this filter tested?"
      q |> limit(10)              →  q          "is the page size pinned?"
      q |> group_by([u], u.role)  →  q          "is this grouping tested?"

  A surviving mutant means **no test exercises** what that clause contributes — the primary
  motivating mutation for a query builder (NOTES "ClauseDrop: the pipe form was the common one").

  Delivery is the shared pipe-aware stage drop (`Mutare.Ecto.StageDrop`): piped, the stage becomes
  `Function.identity/1`; written directly, the call collapses to its query argument. The call is
  resolved through `Mutare.Calls`, so it matches the direct, aliased, and (common)
  `import Ecto.Query` forms alike, and never a same-named user function.

  ## Families

  The recorded family mirrors `Mutare.Ecto.Query`, so the **same** semantic mutation carries the
  **same** family regardless of the syntax used:

    * `where`/`or_where`/`having`/`or_having` → **`:filter_drop`**;
    * `limit`/`offset` → **`:bound`** (the bound family also covers the `n`→`n±1` bumps);
    * every other clause builder (`group_by`, `distinct`, `select`/`select_merge`, `join`,
      `preload`, `lock`, `with_cte`, `windows`, the set-operation macros) → **`:clause_drop`**.

  `order_by`/`prepend_order_by` are deliberately **not** droppable (an unordered query's row order
  is SQL-unspecified); the implicit-direction flip in `Mutare.Ecto.Ordering` is the reliable
  ordering mutant instead.

  ## A drop weakens the query, or breaks it

  Which one depends on the stages *after* the dropped one, and a stage is mutated alone — a
  pipeline is assembled at runtime, often across functions, and `mutate/2` is offered one call
  at a time — so both kinds are emitted under the same family:

    * **Nothing later needs the stage** — a filtering join, a `group_by`, a `distinct`, a
      `preload`. The mutant is the query without it, and a kill means a test pins what the
      stage contributes.
    * **A later stage needs what it provided** — a join's binding (by position or by `as:`
      name), the `windows` name an `over/2` uses, the `limit` a `with_ties` qualifies, the CTE
      a join reads, a schemaless source's `select`. The mutant is no query at all: it raises
      as the pipeline is built (`with_ties`, a named binding), as Ecto plans it (a positional
      binding, a window, the missing `select`), or at the engine (the CTE's table). Any test
      that executes the query kills it, whatever it asserts — so the kill shows that the stage
      *runs*, not that its effect is tested.
    * **In between**: dropping a join ahead of another runs, with every later positional
      binding shifted onto the freed slot — `[p, c]`'s `c` now names the next join's table.

  None of this reaches the single build. These macros assemble the query at runtime, so a broken
  dependency raises only under its own mutant — the inactive branches, and every other mutant
  in the file, are untouched. The `from` form differs exactly there: Ecto expands the whole
  keyword list at compile time, so a dropped `join:` would leave `where: c.x` naming an unbound
  variable in the metamutant itself. That is why `Mutare.Ecto.Query` drops a `limit:` together
  with its `with_ties:`; a `from` join drop would first have to prove the binding unreferenced,
  and none is offered. Telling the two kinds apart *here* needs the rest of the pipeline in
  view (NOTES "Stage drops: a dependency break is not told from a weakened query").
  """

  alias Mutare.Ecto.{Context, StageDrop, Surface}

  @behaviour Mutare.Ecto.SubMutator

  @doc """
  Stage-drop mutations for an `Ecto.Query` clause macro as tags, or `[]`.
  Pipe-aware: the `pipe_mode` from `context` determines identity-vs-first-argument delivery.
  """
  @spec mutations(Macro.t(), Context.t()) :: [Mutare.Ecto.Tag.t()]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %Context{pipe_mode: pipe_mode}),
    do: StageDrop.mutations(node, Ecto.Query, &Surface.stage_drop_family/1, pipe_mode)
end
