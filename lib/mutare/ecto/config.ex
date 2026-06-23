defmodule Mutare.Ecto.Config do
  @moduledoc false
  # Reads the plugin's per-instance options (the `opts` of a `{Mutare.Ecto, opts}` entry, reaching
  # a callback as `context.opts`): which SQL **families** are enabled and which SQL **dialects** to
  # gate dialect-specific mutations on. Listing the plugin twice with different `families:`/`as:`
  # (and/or `repo:`) is how a user narrows the catalog, names a sub-family in the report, or covers
  # multiple repos — see `DESIGN.md`, "Configuration".

  # Every SQL family the plugin can emit, the source of truth for `families: :all` and for
  # validating a configured subset. Grouped by the surface they mutate:
  #
  #   * in-fragment (`where`/`having`, via the host): comparison, connective, null_predicate,
  #     membership, fragment_literal, binding_reorder;
  #   * whole-query / clause-macro: filter_drop (drop a where/having), bound (limit/offset),
  #     ordering, join_type, aggregate (in `select` and `Repo.aggregate`);
  #   * changeset: validation_drop.
  @families ~w(
    comparison connective null_predicate membership fragment_literal binding_reorder
    filter_drop ordering bound join_type aggregate validation_drop
  )a

  # The families whose survivors may be **legitimately unkillable without a `NULL`/boundary
  # fixture** — their equivalence reasoning is SQL's three-valued logic, so a surviving `==`/`!=`
  # or `and`/`or` mutant on a nullable column (or an `is_nil` flip) can be honest signal that the
  # kill needs boundary/NULL data, distinct from a plain "your test is missing". Surfaced under
  # their own report name via the `:as` convention (see `Mutare.Ecto.equivalence_sensitive_families/0`).
  @equivalence_sensitive ~w(comparison connective null_predicate)a

  @doc "Every family the plugin can emit (the `:all` set)."
  @spec all_families() :: [atom()]
  def all_families, do: @families

  @doc "The families whose survivors may need a `NULL`/boundary fixture to kill (see the report note)."
  @spec equivalence_sensitive_families() :: [atom()]
  def equivalence_sensitive_families, do: @equivalence_sensitive

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
