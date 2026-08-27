defmodule Mutare.Ecto.Equivalence do
  @moduledoc false
  # The families whose survivors may be **legitimately unkillable for a data reason**, not a test
  # gap — each carrying a report *note* phrased for its **own** equivalence reason, so the report
  # reads as honest signal — and the `finalize/2` funnel that applies the `families:` filter and
  # attaches that note to every mutation the plugin produces.
  #
  # The reasons are genuinely distinct (and only the connective one is actually SQL three-valued
  # logic — the rest turn on boundary values, NULL exclusion, NULL ordering, or join cardinality),
  # so each gets a note that names the specific data a kill needs rather than one catch-all
  # "three-valued logic" string:
  #
  #   * `:comparison` — two sub-cases, by the operator swapped. A strict↔non-strict swap
  #     (`<`↔`<=`, `>`↔`>=`) differs only on a row sitting exactly on the bound
  #     (`@comparison_boundary_note`); an `==`↔`!=` swap differs on every concrete value but treats
  #     NULLs alike (both exclude them), so it survives only when no non-NULL row exists
  #     (`@comparison_equality_note`). `note/2` picks between them from the finer operator label.
  #   * `:connective` (`@connective_note`) — `and`↔`or`. The one genuine three-valued-logic case:
  #     they coincide unless some row has the two operands disagreeing, a NULL operand counting as
  #     neither true nor false.
  #   * `:null_predicate` (`@null_predicate_note`) — `is_nil`↔`not is_nil`. Complementary row sets,
  #     told apart only by which rows are NULL.
  #   * `:arithmetic` — two sub-cases, by the operator swapped. `+`↔`-` compute the same value
  #     exactly when the right operand is 0 — the shared identity — so an all-zero column makes the
  #     swap equivalent (`@arithmetic_additive_note`); `*`↔`/` coincide when the right operand is ±1
  #     or the left is 0 (`@arithmetic_multiplicative_note`) — a zero *divisor*, by contrast, makes
  #     the swapped query raise, which is a kill, not an equivalence. `note/2` picks between them
  #     from the finer operator label, like `:comparison`.
  #   * `:coalesce` — two sub-cases, by the position of the dropped call. In a value position
  #     (`@coalesce_note`) `coalesce(x, default)` → `x` differs exactly on the rows where `x` is
  #     NULL (the default's whole purpose), so with no NULL row seeded the drop is legitimately
  #     equivalent. In an **ordering** position (`@coalesce_ordering_note` — the
  #     `"coalesce_in_ordering"` finer label `Mutare.Ecto.Scalar` attaches for an `order_by`
  #     value or an `over/2` window's `order_by:` option) the drop needs more than NULL rows: it
  #     re-sorts only those rows to the engine's *default* NULL placement (engine-defined, not
  #     Ecto-defined — Postgres sorts NULL as larger than every value, SQLite/MySQL as smaller;
  #     see `Mutare.Ecto.Ordering`), so a fallback that would rank them in that same place is
  #     legitimately unobservable on that engine. `note/2` picks between them from the finer
  #     label, like `:comparison`.
  #   * `:temporal` (`@temporal_note`) — `ago(n, unit)`↔`from_now(n, unit)`. The two instants sit
  #     the same distance on opposite sides of now, so a comparison against them differs only for
  #     rows whose timestamp falls between them — all-historical (or all-far-future) data makes
  #     the flip legitimately equivalent.
  #   * `:ordering_nulls` (`@ordering_nulls_note`) — `*_nulls_first`↔`*_nulls_last`. Not three-valued
  #     logic at all but NULL *ordering*: the placement only shows when the ordered column holds NULL
  #     rows.
  #   * `:join_type` (`@join_note`) — INNER↔LEFT↔RIGHT↔FULL. Differs only when an *orphan* row exists
  #     (a preserved-side row with no match on the other); a mandatory/complete FK makes every row
  #     match, so the swap is legitimately equivalent.
  #
  # The per-mutant note rides onto a Site via `finalize/2` (`c:Mutare.Mutator.finalize/2`), which
  # core runs on **both** delivery paths — the selector host's `:mutants` and a plain `mutate/2`
  # return. So the in-fragment families surface the advisory through the host, and the
  # whole-`from`/clause-macro families (`:ordering_nulls`, `:join_type`) through `mutate/2`. Surfaced
  # under their own report name via the `:as` convention (`sensitive_families/0`, public as
  # `Mutare.Ecto.equivalence_sensitive_families/0`).

  alias Mutare.Ecto.Config
  alias Mutare.Mutator.Mutation

  @comparison_boundary_note "kill may require a row whose value sits exactly on the bound — strict and non-strict comparisons (< vs <=, > vs >=) select the same rows except one equal to the bound"
  @comparison_equality_note "kill may require a non-NULL row — == and != differ on every concrete value but both exclude NULLs (compared as unknown), so they coincide only when every row is NULL"
  @connective_note "kill may require a row where the operands disagree — and/or coincide while both operands are true or both false on every row (SQL three-valued logic: a NULL operand is unknown, neither)"
  @null_predicate_note "kill may require NULL data in the column — is_nil and not is_nil keep complementary row sets, told apart only by which rows are NULL"
  @arithmetic_additive_note "kill may require a row whose right operand is nonzero — a + b and a - b compute the same value exactly when b is 0 (the identity of both)"
  @arithmetic_multiplicative_note "kill may require a row whose right operand is not ±1 (with a nonzero left) — a * b and a / b coincide there, while a zero divisor raises (a kill, not an equivalence)"
  @coalesce_note "kill may require NULL rows in the wrapped expression — coalesce(x, default) and x differ only where x is NULL, the exact rows the default exists for"
  @coalesce_ordering_note "kill may require NULL rows in the wrapped expression and a test pinning where they rank — in an ordering position the drop re-sorts only those rows to the engine's default NULL placement (Postgres sorts NULL as larger than every value, SQLite/MySQL as smaller), which may coincide with where the fallback already put them"
  @temporal_note "kill may require a row timestamped near now — ago(n, unit) and from_now(n, unit) sit the same distance on opposite sides of now, so comparisons against them differ only for rows between the two instants"
  @ordering_nulls_note "kill may require NULL rows in the ordered column — nulls_first and nulls_last only change where NULLs sort, ordering all other rows identically"
  @join_note "kill may require an orphan row — a preserved-side row with no match (join kinds coincide when every row matches)"

  # The note for each equivalence-sensitive family; the single source of truth for the set (a family
  # is equivalence-sensitive iff it appears here). `sensitive_families/0` derives the ordered set by
  # filtering `Config.all_families/0`. `:comparison`, `:arithmetic`, and `:coalesce` map to their
  # default sub-case notes; `note/2` overrides them with `@comparison_equality_note` for an
  # `==`/`!=` swap, `@arithmetic_multiplicative_note` for a `*`/`/` swap, and
  # `@coalesce_ordering_note` for an ordering-position drop.
  @notes %{
    comparison: @comparison_boundary_note,
    connective: @connective_note,
    null_predicate: @null_predicate_note,
    arithmetic: @arithmetic_additive_note,
    coalesce: @coalesce_note,
    temporal: @temporal_note,
    ordering_nulls: @ordering_nulls_note,
    join_type: @join_note
  }

  @doc "The families whose survivors may be unkillable for a data reason (see the report note)."
  @spec sensitive_families() :: [Config.family()]
  def sensitive_families, do: Enum.filter(Config.all_families(), &Map.has_key?(@notes, &1))

  @doc """
  The report note for a `family`'s mutants — a string for an equivalence-sensitive family
  (surfaced on each such mutant's Site), or `nil` for an ordinary family (a bare mutant). The
  optional `finer` label refines the sub-case families: an `==`/`!=` swap reads `:comparison`'s
  NULL-exclusion note (every other comparison the boundary note), a `*`/`/` swap reads
  `:arithmetic`'s multiplicative-identity note (a `+`/`-` swap the additive one), and an
  ordering-position drop (`"coalesce_in_ordering"`) reads `:coalesce`'s engine-default-placement
  note (a value-position drop the plain NULL-data one).
  """
  @spec note(Config.family(), Mutation.variant()) :: String.t() | nil
  def note(family, finer \\ nil)

  def note(:comparison, finer) when finer in ["==", "!="], do: @comparison_equality_note
  def note(:arithmetic, finer) when finer in ["*", "/"], do: @arithmetic_multiplicative_note
  def note(:coalesce, "coalesce_in_ordering"), do: @coalesce_ordering_note
  def note(family, _finer), do: Map.get(@notes, family)

  @doc """
  The tag → filter → enrich funnel, defined once (`c:Mutare.Mutator.finalize/2` —
  `Mutare.Ecto.finalize/2` delegates here). Core applies it to every mutation the plugin produces,
  on **both** delivery paths — a `mutate/2` return and a host target's `:mutants` — just before
  recording, so no delivery site can forget the filter or the note. It reads the mutation's
  leading variant label (attached by `Mutare.Ecto.Tag.to_mutation/1`) as its SQL family:

    * a **disabled** family (the run's `families:` selection) is dropped — `:skip`;
    * an **enabled** one gains its equivalence advisory (`note/2`, refined for
      `:comparison`/`:arithmetic` by the finer operator label), else a `nil` note. A survivor of an
      equivalence-sensitive family reads "… kill may require …".

  A relayed island mutant (explicit `producer:` — the host's core sub-contract) never reaches
  this funnel: core skips finalize for it, because the producing core family's own funnel already
  ran when the mutation was generated.
  """
  @spec finalize(Mutation.t(), map()) :: Mutation.t() | :skip
  def finalize(%Mutation{variant: [family | finer]} = mutation, context) do
    if Config.family_enabled?(Config.from_context(context), family),
      do: %{mutation | note: note(family, List.first(finer))},
      else: :skip
  end
end
