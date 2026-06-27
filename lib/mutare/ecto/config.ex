defmodule Mutare.Ecto.Config do
  @moduledoc false
  # Reads the plugin's per-instance options (the `opts` of a `{Mutare.Ecto, opts}` entry, reaching
  # a callback as `context.opts`): which SQL **families** are enabled and which SQL **dialects** to
  # gate dialect-specific mutations on. Listing the plugin twice with different `families:`/`as:`
  # (and/or `repo:`) is how a user narrows the catalog, names a sub-family in the report, or covers
  # multiple repos — see `DESIGN.md`, "Configuration".

  alias Mutare.Ecto.AST
  alias Mutare.Mutator.Mutation

  @valid_dialects ~w(postgres mysql sqlite)a

  # Every SQL family the plugin can emit, the source of truth for `families: :all` and for
  # validating a configured subset. Grouped by the surface they mutate:
  #
  #   * in-fragment (`where`/`having`, via the host): comparison, connective, null_predicate,
  #     membership, fragment_literal, binding_reorder;
  #   * binding_reorder also fires **in place** on every other binding-list macro (`select`,
  #     `order_by`, `join`, … — `Mutare.Ecto.BindingReorder`): a positional binding transposition;
  #   * whole-query / clause-macro: filter_drop (drop a where/having), bound (limit/offset),
  #     ordering (sort direction), ordering_nulls (NULLs placement), join_type,
  #     aggregate (`sum`↔`avg`/`min`↔`max` in `select`/`order_by`/`Repo.aggregate` delivered in
  #     place, and in a hosted `having` condition via `Mutare.Ecto.Host`), query_terminal (`first`↔`last`),
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

  @enforce_keys [:families, :dialects, :repo_key]
  defstruct [:families, :dialects, :repo_key]

  @type t :: %__MODULE__{
          families: MapSet.t(atom()),
          dialects: MapSet.t(atom()),
          repo_key: [atom()] | atom() | nil
        }

  @doc "Validate and normalize one plugin option list."
  @spec parse!(keyword()) :: t()
  def parse!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Mutare.Ecto options must be a keyword list, got: #{inspect(opts)}"
    end

    %__MODULE__{
      families: opts |> Keyword.get(:families, :all) |> parse_families!(),
      dialects: opts |> Keyword.get(:dialects, []) |> parse_dialects!(),
      repo_key: opts |> Keyword.get(:repo) |> parse_repo!()
    }
  end

  def parse!(other),
    do: raise(ArgumentError, "Mutare.Ecto options must be a keyword list, got: #{inspect(other)}")

  @doc "The normalized config already attached to a callback context, or one parsed from its opts."
  @spec from_context(map()) :: t()
  def from_context(%{ecto_config: %__MODULE__{} = config}), do: config
  def from_context(%{opts: opts}), do: parse!(opts)
  def from_context(_context), do: parse!([])

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
  @spec families(keyword() | t()) :: [atom()]
  def families(%__MODULE__{families: enabled}),
    do: Enum.filter(@families, &MapSet.member?(enabled, &1))

  def families(opts), do: opts |> parse!() |> families()

  @doc "Whether `family` is enabled by `opts`."
  @spec family_enabled?(keyword() | t(), atom()) :: boolean()
  def family_enabled?(%__MODULE__{families: families}, family),
    do: MapSet.member?(families, family)

  def family_enabled?(opts, family), do: opts |> parse!() |> family_enabled?(family)

  @doc """
  The configured `repo`'s resolved module key (`Mutare.Ecto.AST.module_key/1`), ready to compare
  against a `Mutare.Transform.Calls.resolved_call/1` module, or `nil` when no `repo:` is set.
  Shared by the Repo-call families (`Mutare.Ecto.RepoWrite`, `Mutare.Ecto.RepoAggregate`).
  """
  @spec repo_key(keyword() | t()) :: [atom()] | atom() | nil
  def repo_key(%__MODULE__{repo_key: repo_key}), do: repo_key
  def repo_key(opts), do: opts |> parse!() |> repo_key()

  @doc "The dialects `opts` enables (default `[]` — the portable core only)."
  @spec dialects(keyword() | t()) :: [atom()]
  def dialects(%__MODULE__{dialects: enabled}),
    do: Enum.filter(@valid_dialects, &MapSet.member?(enabled, &1))

  def dialects(opts), do: opts |> parse!() |> dialects()

  @doc """
  Whether a mutation gated to the dialects in `supported` is enabled by `opts` — true when any
  configured dialect supports it. With no `dialects:` configured nothing dialect-specific fires,
  so the portable core is the conservative default.
  """
  @spec dialect_enabled?(keyword() | t(), [atom()]) :: boolean()
  def dialect_enabled?(%__MODULE__{dialects: dialects}, supported),
    do: Enum.any?(supported, &MapSet.member?(dialects, &1))

  def dialect_enabled?(opts, supported), do: opts |> parse!() |> dialect_enabled?(supported)

  defp parse_families!(:all), do: MapSet.new(@families)

  defp parse_families!(families) when is_list(families) do
    case families -- @families do
      [] ->
        MapSet.new(families)

      unknown ->
        raise ArgumentError,
              "unknown Mutare.Ecto families: #{inspect(unknown)} — valid families are " <>
                inspect(@families)
    end
  end

  defp parse_families!(other) do
    raise ArgumentError,
          "Mutare.Ecto :families must be :all or a list, got: #{inspect(other)}"
  end

  defp parse_dialects!(dialects) when is_list(dialects) do
    case dialects -- @valid_dialects do
      [] ->
        MapSet.new(dialects)

      unknown ->
        raise ArgumentError,
              "unknown Mutare.Ecto dialects: #{inspect(unknown)} — valid dialects are " <>
                inspect(@valid_dialects)
    end
  end

  defp parse_dialects!(other) do
    raise ArgumentError, "Mutare.Ecto :dialects must be a list, got: #{inspect(other)}"
  end

  defp parse_repo!(nil), do: nil
  defp parse_repo!(module) when is_atom(module), do: AST.module_key(module)

  defp parse_repo!(other) do
    raise ArgumentError, "Mutare.Ecto :repo must be a module atom, got: #{inspect(other)}"
  end
end
