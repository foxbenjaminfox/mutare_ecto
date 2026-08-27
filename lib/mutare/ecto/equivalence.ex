defmodule Mutare.Ecto.Equivalence do
  @moduledoc false
  # The one home of two things: the **equivalence-sensitive families** — those whose survivors
  # may be legitimately unkillable for a data reason, not a test gap — each with a report *note*
  # phrased for its **own** reason, so the report reads as honest signal; and the `finalize/2`
  # funnel (below) that applies the `families:` filter and attaches that note to every mutation
  # the plugin produces.
  #
  # The reasons are genuinely distinct (only the connective one is actually SQL three-valued
  # logic — the rest turn on boundary values, NULL exclusion, NULL ordering, or join cardinality),
  # so each note names the specific data a kill needs rather than one catch-all string. The
  # `@…_note` strings below are the single statement of each family's reason — written as the
  # report line itself, so the rationale and what the user reads cannot drift. Three families
  # split into sub-cases that `note/2` selects by the mutant's finer label:
  #
  #   * `:comparison` — a strict↔non-strict swap needs a row on the bound; `==`↔`!=` needs a
  #     non-NULL row (both exclude NULLs);
  #   * `:arithmetic` — `+`↔`-` needs a nonzero right operand; `*`↔`/` a right operand off ±1 (a
  #     zero divisor raises — a kill, not an equivalence);
  #   * `:coalesce` — in a value position the drop needs a NULL row; under the
  #     `"coalesce_in_ordering"` label `Mutare.Ecto.Scalar` attaches to a sort-key drop it also
  #     needs the fallback to disagree with the engine's default NULL placement (the per-engine
  #     table is `Mutare.Ecto.Ordering`'s).
  #
  # The set is public as `Mutare.Ecto.equivalence_sensitive_families/0` (`sensitive_families/0`),
  # so a user can group these survivors under their own report name via the `:as` convention.

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
  # filtering `Config.all_families/0`. The three sub-case families map to their default arm;
  # `note/2` selects the other by the mutant's finer label.
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
  optional `finer` label selects the sub-case note for `:comparison`/`:arithmetic`/`:coalesce`
  (the module header lists them).
  """
  @spec note(Config.family(), Mutation.variant()) :: String.t() | nil
  def note(family, finer \\ nil)

  def note(:comparison, finer) when finer in ["==", "!="], do: @comparison_equality_note
  def note(:arithmetic, finer) when finer in ["*", "/"], do: @arithmetic_multiplicative_note
  def note(:coalesce, "coalesce_in_ordering"), do: @coalesce_ordering_note
  def note(family, _finer), do: Map.get(@notes, family)

  @doc """
  The tag → filter → enrich funnel, defined once (`c:Mutare.Mutator.finalize/2` —
  `Mutare.Ecto.finalize/2` unpacks the `%Config{}` from core's context and delegates here, so this
  body is context-free). Producers stay pure — every tag becomes a
  `Mutation` carrying `variant: [family | finer]` (`Mutare.Ecto.Tag.to_mutation/1`) — and core
  applies this funnel to every mutation the plugin produces, on **both** delivery paths (a
  `mutate/2` return and a host target's `:mutants`), just before recording, so no delivery site
  can forget the filter or the note. It reads the mutation's leading variant label as its SQL
  family:

    * a **disabled** family (the run's `families:` selection) is dropped — `:skip`;
    * an **enabled** one gains its equivalence advisory (`note/2`, refined by the finer label),
      else a `nil` note. A survivor of an equivalence-sensitive family reads "… kill may require …".

  This is how the in-fragment families surface their note through the host, and the
  whole-`from`/clause-macro families (`:ordering_nulls`, `:join_type`) through `mutate/2`. A
  relayed island mutant (explicit `producer:`, `Mutare.Ecto.Island`) never reaches this funnel:
  core skips finalize for it, because the producing family's own funnel already ran when the
  mutation was generated.
  """
  @spec finalize(Mutation.t(), Config.t()) :: Mutation.t() | :skip
  def finalize(%Mutation{variant: [family | finer]} = mutation, %Config{} = config) do
    if Config.family_enabled?(config, family),
      do: %{mutation | note: note(family, List.first(finer))},
      else: :skip
  end
end
