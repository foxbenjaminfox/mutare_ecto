defmodule Mutare.Ecto.Config do
  @moduledoc false
  # Reads the plugin's per-instance options (the `opts` of a `{Mutare.Ecto, opts}` entry, reaching
  # a callback as `context.opts`): which SQL **families** are enabled and which SQL **dialects** to
  # gate dialect-specific mutations on. Listing the plugin twice with different `families:`/`as:`
  # (and/or `repo:`) is how a user narrows the catalog, names a sub-family in the report, or covers
  # multiple repos — see `DESIGN.md`, "Configuration".

  alias Mutare.Mutator.Mutation

  # Every SQL family the plugin can emit, the source of truth for `families: :all` and for
  # validating a configured subset. Grouped by the surface they mutate:
  #
  #   * in-fragment (`where`/`having`, via the host): comparison, connective, null_predicate,
  #     membership, fragment_literal, binding_reorder;
  #   * binding_reorder also fires **in place** on every other binding-list macro (`select`,
  #     `order_by`, `join`, … — `Mutare.Ecto.BindingReorder`): a positional binding transposition;
  #   * whole-query / clause-macro: filter_drop (drop a where/having), bound (limit/offset),
  #     ordering (sort direction), ordering_nulls (NULLs placement), join_type,
  #     aggregate (in `select` and `Repo.aggregate`), query_terminal (`first`↔`last`),
  #     clause_drop (drop a standalone/pipe order_by/select/join/… stage — `Mutare.Ecto.ClauseDrop`);
  #   * repo write: persistence (insert/update/delete → apply_action), on_conflict (`:nothing`↔`:raise`);
  #   * changeset: validation_drop (validators/constraints), hook_drop (prepare_changes/optimistic_lock).
  @families ~w(
    comparison connective null_predicate membership fragment_literal binding_reorder
    filter_drop ordering ordering_nulls bound join_type aggregate query_terminal clause_drop
    persistence on_conflict validation_drop hook_drop
  )a

  # The families whose survivors may be **legitimately unkillable without a `NULL`/boundary
  # fixture** — their equivalence reasoning is SQL's three-valued logic, so a surviving `==`/`!=`
  # or `and`/`or` mutant on a nullable column (or an `is_nil` flip) can be honest signal that the
  # kill needs boundary/NULL data, distinct from a plain "your test is missing". `ordering_nulls`
  # joins them: a `*_nulls_first`↔`*_nulls_last` flip is only killable when the result actually
  # holds NULL rows in the ordered column. Surfaced under their own report name via the `:as`
  # convention (see `Mutare.Ecto.equivalence_sensitive_families/0`).
  #
  # The per-mutant *note* (below) rides onto a Site via a `%Mutare.Mutator.Mutation{}` (`noted/2`),
  # which core accepts on **both** delivery paths — the selector host's `:mutants` and a plain
  # `mutate/2` return. So all four families surface the advisory inline: the three in-fragment ones
  # through the host, and `ordering_nulls` (a whole-`from`/clause-macro rewrite) through `mutate/2`.
  @equivalence_sensitive ~w(comparison connective null_predicate ordering_nulls)a

  # The advisory recorded on an equivalence-sensitive mutant's `Mutare.Site` (and shown in the
  # report) — honest signal that a survivor may need a fixture to kill, distinct from a test gap.
  @equivalence_note "kill may require NULL/boundary data (SQL three-valued logic)"

  @doc "Every family the plugin can emit (the `:all` set)."
  @spec all_families() :: [atom()]
  def all_families, do: @families

  @doc "The families whose survivors may need a `NULL`/boundary fixture to kill (see the report note)."
  @spec equivalence_sensitive_families() :: [atom()]
  def equivalence_sensitive_families, do: @equivalence_sensitive

  @doc """
  The report note for a `family`'s mutants — a string for an equivalence-sensitive family
  (surfaced on each such mutant's Site), or `nil` for an ordinary family (a bare mutant).
  """
  @spec equivalence_note(atom()) :: String.t() | nil
  def equivalence_note(family) when family in @equivalence_sensitive, do: @equivalence_note
  def equivalence_note(_family), do: nil

  @doc """
  Tag a mutant `node` with its family's report note, ready to return from `mutate/2` or a host
  target's `:mutants`.

  An equivalence-sensitive family's node is wrapped in a `%Mutare.Mutator.Mutation{}` carrying the
  advisory (so it rides onto the `Mutare.Site`); every other family yields the bare node (the
  common, note-free case). Core accepts both forms on either delivery path.
  """
  @spec noted(atom(), Macro.t()) :: Macro.t() | Mutation.t()
  def noted(family, node) do
    case equivalence_note(family) do
      nil -> node
      note -> Mutation.new(node, note)
    end
  end

  @doc """
  The families enabled by `opts` — the configured `families:` list, or all of them when it is
  `:all` (the default) or unset. Raises on an unknown family name, so a typo'd `families:` entry
  fails loudly rather than silently mutating nothing.
  """
  @spec families(keyword()) :: [atom()]
  def families(opts) do
    case Keyword.get(opts, :families, :all) do
      :all -> @families
      list when is_list(list) -> validate!(list)
    end
  end

  defp validate!(list) do
    case list -- @families do
      [] ->
        list

      unknown ->
        raise ArgumentError,
              "unknown Mutare.Ecto families: #{inspect(unknown)} — valid families are " <>
                inspect(@families)
    end
  end

  @doc "Whether `family` is enabled by `opts`."
  @spec family_enabled?(keyword(), atom()) :: boolean()
  def family_enabled?(opts, family), do: family in families(opts)

  @doc "The dialects `opts` enables (default `[]` — the portable core only)."
  @spec dialects(keyword()) :: [atom()]
  def dialects(opts), do: Keyword.get(opts, :dialects, [])

  @doc """
  Whether a mutation gated to the dialects in `supported` is enabled by `opts` — true when any
  configured dialect supports it. With no `dialects:` configured nothing dialect-specific fires,
  so the portable core is the conservative default.
  """
  @spec dialect_enabled?(keyword(), [atom()]) :: boolean()
  def dialect_enabled?(opts, supported), do: Enum.any?(dialects(opts), &(&1 in supported))
end
