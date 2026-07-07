defmodule Mutare.Ecto.ClauseDrop do
  @moduledoc """
  Drop a standalone/pipe **query clause** — the composable cousin of `Mutare.Ecto.Query`'s
  whole-`from` clause drop, and the query-side twin of `Mutare.Ecto.Changeset`'s validator drop.
  Where `Query` removes a `where:`/`limit:` clause from a `from(…)` keyword list, this removes the
  same kinds of clause written as a standalone call or pipe stage:

      q |> where([u], u.active)   →  q          "is this filter tested?"
      q |> limit(10)              →  q          "is the page size pinned?"
      q |> group_by([u], u.role)  →  q          "is this grouping tested?"

  A surviving mutant means **no test exercises** what that clause contributes. This is the
  primary motivating mutation for a query builder, yet it was previously only reachable in the
  `from`-keyword syntax — the pipe/standalone forms are far more common.

  ## Pipe-aware delivery

  Exactly `Mutare.Ecto.Changeset`'s mechanic (itself core's `CallRemoval` delivery):

    * **piped** (`q |> where(…)`) — the query is the `|>` left side, so the stage is replaced by
      `Function.identity/1` (`q |> Function.identity()` ≡ `q`). The absolute `Elixir.Function` is
      alias-proof (a user `alias X, as: Function` can't redirect it).
    * **direct** (`where(q, …)`) — the query is the first argument, so the call collapses to it.

  The call is resolved through `Mutare.Calls`, so it matches the direct, aliased, and
  (common) `import Ecto.Query` forms alike, and never a same-named user function.

  ## Families

  The recorded family mirrors `Mutare.Ecto.Query`, so the **same** semantic mutation carries the
  **same** family regardless of which syntax wrote it:

    * `where`/`or_where`/`having`/`or_having` → **`:filter_drop`**;
    * `limit`/`offset` → **`:bound`** (the bound family also covers the `n`→`n±1` bumps);
    * every other clause builder (`group_by`, `distinct`, `select`/`select_merge`, `join`,
      `preload`, `lock`, `with_cte`, `windows`, the set-operation macros) → **`:clause_drop`**.

  `order_by`/`prepend_order_by` are deliberately **not** droppable: dropping an `ORDER BY` yields
  an unordered query whose row order SQL leaves unspecified, so the mutant's survival tracked
  engine nondeterminism rather than a test gap. Its reliable cousin — re-tagging the implicit
  `asc` of a bare ordering to `desc` — lives in `Mutare.Ecto.Ordering` instead.

  A dropped stage can leave a later stage referencing a binding/CTE/window the query no longer
  has — but these macros build the query at *runtime*, so that surfaces as a runtime error when
  the mutant is exercised (killing it), never a compile error of the single metamutant build.
  """

  alias Mutare.Ecto.{Config, StageDrop, Surface}

  use Mutare.Ecto.SubMutator

  @doc """
  Stage-drop mutations for an `Ecto.Query` clause macro as `{family, node}` pairs, or `[]`.
  Pipe-aware: the `pipe_mode` from `context` decides identity-vs-first-argument delivery.
  """
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [{Config.family(), Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %{pipe_mode: pipe_mode}),
    do: StageDrop.mutations(node, Ecto.Query, &Surface.stage_drop_family/1, pipe_mode)
end
