defmodule Mutare.Ecto.Config do
  @moduledoc false
  # Parses the plugin's per-instance options (the `opts` of a `{Mutare.Ecto, opts}` entry) **once**,
  # at spec resolution: `Mutare.Ecto.init/1` (`c:Mutare.Mutator.init/1`) calls `parse!/1`, so a
  # typo'd option raises at startup next to core's own option validation, and core delivers the
  # result to every context-aware callback (`mutate/2`, `host/2`) as `context.config` — which SQL
  # **families** are enabled, which SQL **dialects** to gate dialect-specific mutations on, and
  # which `repo:` the Repo-call families match. Listing the plugin twice with different
  # `families:`/`as:` (and/or `repo:`) is how a user narrows the catalog, names a sub-family in the
  # report, or covers multiple repos.
  #
  # Production only ever holds the parsed `%Config{}` — every accessor below takes the struct, and
  # a unit test that needs one builds it through `parse!/1`. What a family *means* once selected —
  # its report note, and the `finalize/2` funnel that applies this selection — is
  # `Mutare.Ecto.Equivalence`'s.

  @valid_options ~w(repo families dialects)a
  @valid_dialects ~w(postgres mysql sqlite)a
  @empty_dialect_set MapSet.new()

  # Every SQL family the plugin can emit, the source of truth for `families: :all` and for
  # validating a configured subset. Grouped by the surface they mutate, each with its owner:
  #
  #   * in-fragment (hosted `where`/`having` — `Mutare.Ecto.Host`; a free-standing `dynamic` —
  #     `Mutare.Ecto.Dynamic`): comparison, connective, null_predicate, membership, temporal, and
  #     the literal arms (`Mutare.Ecto.Fragment`); arithmetic and coalesce (`Mutare.Ecto.Scalar`)
  #     and aggregate (`Mutare.Ecto.Aggregate`), which are also delivered in place inside
  #     `select`/`order_by` values (and `aggregate` in `Repo.aggregate` — `Mutare.Ecto.RepoAggregate`);
  #   * binding_reorder — `Mutare.Ecto.BindingReorder` (a `from` source list: `Mutare.Ecto.Query`);
  #   * whole-`from` / clause-macro: filter_drop and clause_drop (`Mutare.Ecto.Query`,
  #     `Mutare.Ecto.ClauseDrop`), bound (the drop there, the ±1 bump hosted pin-only —
  #     `Mutare.Ecto.Bound`), ordering and ordering_nulls (`Mutare.Ecto.Ordering`), join_type
  #     (`Mutare.Ecto.Query`), combination (`Mutare.Ecto.Combination`), query_terminal
  #     (`Mutare.Ecto.QueryTerminal`);
  #   * repo write: persistence, on_conflict (`Mutare.Ecto.RepoWrite`);
  #   * changeset: validation_drop, hook_drop (`Mutare.Ecto.Changeset`).
  #
  # Generates the catalog machinery from this one declaration: `@type family` (the union),
  # `all_families/0` (`:all`, ordered), `default_families/0` (`:all` minus `:opt_in`),
  # `parse_families!/1` (the `:default | :all | list | {base, except: […]}` grammar, core's own),
  # and `family_enabled?/2` (overridden below to take the parsed struct) — so the plugin parses
  # `families:` exactly as core parses `{:builtins, except: […]}`, with fail-loud errors blaming
  # "Mutare.Ecto".
  #
  # The `:opt_in` entries are the in-fragment literal arms that are **off by default** (why:
  # `Mutare.Ecto`'s "Configuration"); a user enables them with `families: :all`, by naming them
  # in an explicit list, or via `{:default, except: …}`/`{:all, except: …}`.
  # (The lists are plain literals — `use` options are expanded with `Macro.expand_literals/2`,
  # which leaves sigils and module attributes unexpanded.)
  use Mutare.Mutator.Families,
    plugin: "Mutare.Ecto",
    all: [
      :comparison,
      :connective,
      :null_predicate,
      :membership,
      :arithmetic,
      :coalesce,
      :temporal,
      :binding_reorder,
      :integer_literal,
      :float_literal,
      :atom_literal,
      :string_literal,
      :boolean_literal,
      :filter_drop,
      :ordering,
      :ordering_nulls,
      :bound,
      :join_type,
      :combination,
      :aggregate,
      :query_terminal,
      :clause_drop,
      :persistence,
      :on_conflict,
      :validation_drop,
      :hook_drop
    ],
    opt_in: [:string_literal, :atom_literal, :boolean_literal]

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
      raise ArgumentError,
            "Mutare.Ecto options must be a keyword list, got a non-keyword list: #{inspect(opts)}"
    end

    validate_option_keys!(opts)

    %__MODULE__{
      families: opts |> Keyword.get(:families, :default) |> parse_families!(),
      dialects: opts |> Keyword.get(:dialects, []) |> parse_dialects!(),
      repo_key: opts |> Keyword.get(:repo) |> parse_repo!()
    }
  end

  def parse!(other),
    do: raise(ArgumentError, "Mutare.Ecto options must be a keyword list, got: #{inspect(other)}")

  @doc "The `Mutare.Ecto.init/1`-normalized config core delivers on every callback context."
  @spec from_context(map()) :: t()
  def from_context(%{config: %__MODULE__{} = config}), do: config

  # Core delivers the `init/1`-parsed struct as `:config` on every per-spec context path
  # (`mutate/2`, `host/2`), so a miss is a programming error — fail loudly rather than silently
  # defaulting to an all-families, no-repo config.
  def from_context(other) do
    raise ArgumentError,
          "Mutare.Ecto.Config.from_context/1 expected a context with the init/1-parsed :config, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  The families `config` enables, in catalog order — the configured `families:` selection, or the
  **default set** (every family except the opt-in `:string_literal`/`:atom_literal`/`:boolean_literal`
  arms) when it was `:default` or unset; `:all` is every family.
  """
  @spec families(t()) :: [family()]
  def families(%__MODULE__{families: enabled}),
    do: Enum.filter(all_families(), &MapSet.member?(enabled, &1))

  # Overrides the generated `family_enabled?/2` (which reads a raw `MapSet` or keyword list) to
  # take the parsed struct — the only shape production ever holds.
  @spec family_enabled?(t(), family()) :: boolean()
  def family_enabled?(%__MODULE__{families: enabled}, family), do: MapSet.member?(enabled, family)

  @doc """
  The configured `repo`'s resolved module key (`Mutare.Calls.module_key/1`), ready to compare
  against a `Mutare.Calls.resolved_call/1` module (or to hand to
  `Mutare.Calls.resolved_call_to/3`, which accepts an encoded key), or `nil` when no `repo:` is
  set. Shared by the Repo-call families (`Mutare.Ecto.RepoWrite`, `Mutare.Ecto.RepoAggregate`).
  """
  @spec repo_key(t()) :: [atom()] | atom() | nil
  def repo_key(%__MODULE__{repo_key: repo_key}), do: repo_key

  @doc "The dialects `config` enables (default `[]` — the portable core only)."
  @spec dialects(t()) :: [atom()]
  def dialects(%__MODULE__{dialects: enabled}),
    do: Enum.filter(@valid_dialects, &MapSet.member?(enabled, &1))

  @doc """
  Whether a mutation gated to the dialects in `supported` is enabled by `config` — true when any
  configured dialect supports it. With no `dialects:` configured nothing dialect-specific fires,
  so the portable core is the conservative default.
  """
  @spec dialect_enabled?(t(), [atom()]) :: boolean()
  def dialect_enabled?(%__MODULE__{dialects: dialects}, supported),
    do: Enum.any?(supported, &MapSet.member?(dialects, &1))

  defp validate_option_keys!(opts) do
    case Keyword.keys(opts) -- @valid_options do
      [] ->
        # Called only for its raise-or-not side effect in parse!/1 — the return value is
        # never bound or used, so its exact shape is unobservable.
        # mutare:ignore[return_value, convention] equivalent — the return value is discarded by every caller
        :ok

      unknown ->
        raise ArgumentError,
              "unknown Mutare.Ecto options: #{inspect(unknown)} — valid options are " <>
                inspect(@valid_options)
    end
  end

  # mutare:ignore[clause_drop] equivalent — the general clause below matches [] too (is_list([]) and [] -- @valid_dialects == []) and returns MapSet.new([]), the same empty set
  defp parse_dialects!([]), do: @empty_dialect_set

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

  # mutare:ignore[clause_drop] equivalent — nil is an atom, so the clause below would handle it via Mutare.Calls.module_key(nil), which itself returns nil unchanged (Macro.classify_atom(nil) isn't :alias)
  defp parse_repo!(nil), do: nil
  defp parse_repo!(module) when is_atom(module), do: Mutare.Calls.module_key(module)

  defp parse_repo!(other) do
    raise ArgumentError, "Mutare.Ecto :repo must be a module atom, got: #{inspect(other)}"
  end
end
