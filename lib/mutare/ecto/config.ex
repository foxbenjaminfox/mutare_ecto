defmodule Mutare.Ecto.Config do
  @moduledoc false
  # Parses the plugin's per-instance options (the `opts` of a `{Mutare.Ecto, opts}` entry) once, at
  # spec resolution — `Mutare.Ecto.init/1` calls `parse!/1`, and core delivers the result to every
  # callback as `context.config`: which SQL **families** are enabled and which SQL **dialects** to
  # gate dialect-specific mutations on. Listing the plugin twice with different `families:`/`as:`
  # (and/or `repo:`) is how a user narrows the catalog, names a sub-family in the report, or covers
  # multiple repos.

  alias Mutare.Mutator.Mutation

  @valid_options ~w(repo families dialects)a
  @valid_dialects ~w(postgres mysql sqlite)a
  @empty_dialect_set MapSet.new()

  # Every SQL family the plugin can emit, the source of truth for `families: :all` and for
  # validating a configured subset. Grouped by the surface they mutate:
  #
  #   * in-fragment (`where`/`having` via the host; a free-standing `dynamic/1,2` via
  #     `Mutare.Ecto.Dynamic`, in place): comparison, connective, null_predicate,
  #     membership, arithmetic, coalesce, temporal, integer_literal, float_literal, atom_literal,
  #     string_literal, boolean_literal — arithmetic and coalesce (the scalar catalog,
  #     `Mutare.Ecto.Scalar`) are also delivered in place inside `select`/`order_by` values;
  #   * binding_reorder — a positional binding transposition (`[a, b]` → `[b, a]`), delivered **in
  #     place** by swapping the written list: `Mutare.Ecto.BindingReorder` for every standalone/pipe
  #     binding-list macro (`where`/`having`/`select`/`order_by`/`join`/…) and `Mutare.Ecto.Query` for
  #     a `from` `[a, b] in q` source. Unused declarations still swap; `_`-prefixed and named
  #     bindings do not. Never a host/body rewrite;
  #   * whole-query / clause-macro: filter_drop (drop a where/having), bound (limit/offset),
  #     ordering (sort direction), ordering_nulls (NULLs placement), join_type,
  #     combination (`intersect`↔`except`/`intersect_all`↔`except_all`, as a `from` clause key or a
  #     standalone/pipe macro name — `Mutare.Ecto.Combination`),
  #     aggregate (`sum`↔`avg`/`min`↔`max` in `select`/`order_by`/`Repo.aggregate` delivered in
  #     place, and in a hosted `having` condition via `Mutare.Ecto.Host`), query_terminal (`first`↔`last`),
  #     clause_drop (drop a standalone/pipe order_by/select/join/… stage — `Mutare.Ecto.ClauseDrop`);
  #   * repo write: persistence (insert/update/delete → apply_action), on_conflict (swap an explicit
  #     `on_conflict:` atom on insert/insert!/insert_all — `:nothing`→`:raise`, `:raise`→`:nothing`,
  #     `:replace_all`→`:nothing`);
  #   * changeset: validation_drop (validators/constraints), hook_drop (prepare_changes/optimistic_lock).
  #
  # Generates the catalog machinery from this one declaration: `@type family` (the union),
  # `all_families/0` (`:all`, ordered), `default_families/0` (`:all` minus `:opt_in`),
  # `parse_families!/1` (the `:default | :all | list | {base, except: […]}` grammar, core's own),
  # and `family_enabled?/2` — so the plugin parses `families:` exactly as core parses
  # `{:builtins, except: […]}`, with fail-loud errors blaming "Mutare.Ecto".
  #
  # The `:opt_in` entries are the in-fragment literal arms that are **off by default**, opt-in for
  # safety. A string, atom, or boolean literal mutant is the most likely to be a noisy/odd
  # survivor — a string or atom because its value space is large (an in-fragment string the
  # broadest), a boolean because a direct boolean literal in a condition is rarely idiomatic — so
  # they are not in the default set: a user enables them with `families: :all`, by naming them in
  # an explicit list, or via `{:default, except: …}`/`{:all, except: …}`. Even when enabled, the
  # structural-position guard in `Mutare.Ecto.Fragment` still suppresses them at a DSL form's
  # structural argument.
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

  # The families whose survivors may be **legitimately unkillable for a data reason**, not a test
  # gap — each carrying a report *note* phrased for its **own** equivalence reason, so the report
  # reads as honest signal. The reasons are genuinely distinct (and only the connective one is
  # actually SQL three-valued logic — the rest turn on boundary values, NULL exclusion, NULL
  # ordering, or join cardinality), so each gets a note that names the specific data a kill needs
  # rather than one catch-all "three-valued logic" string:
  #
  #   * `:comparison` — two sub-cases, by the operator swapped. A strict↔non-strict swap
  #     (`<`↔`<=`, `>`↔`>=`) differs only on a row sitting exactly on the bound
  #     (`@comparison_boundary_note`); an `==`↔`!=` swap differs on every concrete value but treats
  #     NULLs alike (both exclude them), so it survives only when no non-NULL row exists
  #     (`@comparison_equality_note`). `equivalence_note/2` picks between them from the finer operator
  #     label.
  #   * `:connective` (`@connective_note`) — `and`↔`or`. The one genuine three-valued-logic case:
  #     they coincide unless some row has the two operands disagreeing, a NULL operand counting as
  #     neither true nor false.
  #   * `:null_predicate` (`@null_predicate_note`) — `is_nil`↔`not is_nil`. Complementary row sets,
  #     told apart only by which rows are NULL.
  #   * `:arithmetic` — two sub-cases, by the operator swapped. `+`↔`-` compute the same value
  #     exactly when the right operand is 0 — the shared identity — so an all-zero column makes the
  #     swap equivalent (`@arithmetic_additive_note`); `*`↔`/` coincide when the right operand is ±1
  #     or the left is 0 (`@arithmetic_multiplicative_note`) — a zero *divisor*, by contrast, makes
  #     the swapped query raise, which is a kill, not an equivalence. `equivalence_note/2` picks
  #     between them from the finer operator label, like `:comparison`.
  #   * `:coalesce` (`@coalesce_note`) — `coalesce(x, default)` → `x`. The two forms differ
  #     exactly on the rows where `x` is NULL (the default's whole purpose), so with no NULL row
  #     seeded the drop is legitimately equivalent.
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
  # The per-mutant note rides onto a Site via a `%Mutare.Mutator.Mutation{}` (`enrich/3`), which core
  # accepts on **both** delivery paths — the selector host's `:mutants` and a plain `mutate/2`
  # return. So the in-fragment families surface the advisory through the host, and the
  # whole-`from`/clause-macro families (`:ordering_nulls`, `:join_type`) through `mutate/2`. Surfaced
  # under their own report name via the `:as` convention (`equivalence_sensitive_families/0`).
  @comparison_boundary_note "kill may require a row whose value sits exactly on the bound — strict and non-strict comparisons (< vs <=, > vs >=) select the same rows except one equal to the bound"
  @comparison_equality_note "kill may require a non-NULL row — == and != differ on every concrete value but both exclude NULLs (compared as unknown), so they coincide only when every row is NULL"
  @connective_note "kill may require a row where the operands disagree — and/or coincide while both operands are true or both false on every row (SQL three-valued logic: a NULL operand is unknown, neither)"
  @null_predicate_note "kill may require NULL data in the column — is_nil and not is_nil keep complementary row sets, told apart only by which rows are NULL"
  @arithmetic_additive_note "kill may require a row whose right operand is nonzero — a + b and a - b compute the same value exactly when b is 0 (the identity of both)"
  @arithmetic_multiplicative_note "kill may require a row whose right operand is not ±1 (with a nonzero left) — a * b and a / b coincide there, while a zero divisor raises (a kill, not an equivalence)"
  @coalesce_note "kill may require NULL rows in the wrapped expression — coalesce(x, default) and x differ only where x is NULL, the exact rows the default exists for"
  @temporal_note "kill may require a row timestamped near now — ago(n, unit) and from_now(n, unit) sit the same distance on opposite sides of now, so comparisons against them differ only for rows between the two instants"
  @ordering_nulls_note "kill may require NULL rows in the ordered column — nulls_first and nulls_last only change where NULLs sort, ordering all other rows identically"
  @join_note "kill may require an orphan row — a preserved-side row with no match (join kinds coincide when every row matches)"

  # The note for each equivalence-sensitive family; the single source of truth for the set (a family
  # is equivalence-sensitive iff it appears here). `equivalence_sensitive_families/0` derives the
  # ordered set by filtering `all_families()`. `:comparison` and `:arithmetic` map to their default
  # sub-case notes; `equivalence_note/2` overrides them with `@comparison_equality_note` for an
  # `==`/`!=` swap and `@arithmetic_multiplicative_note` for a `*`/`/` swap.
  @equivalence_notes %{
    comparison: @comparison_boundary_note,
    connective: @connective_note,
    null_predicate: @null_predicate_note,
    arithmetic: @arithmetic_additive_note,
    coalesce: @coalesce_note,
    temporal: @temporal_note,
    ordering_nulls: @ordering_nulls_note,
    join_type: @join_note
  }

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

  @doc "The families whose survivors may be unkillable for a data reason (see the report note)."
  @spec equivalence_sensitive_families() :: [family()]
  def equivalence_sensitive_families,
    do: Enum.filter(all_families(), &Map.has_key?(@equivalence_notes, &1))

  @doc """
  The report note for a `family`'s mutants — a string for an equivalence-sensitive family
  (surfaced on each such mutant's Site), or `nil` for an ordinary family (a bare mutant). The
  optional `finer` operator label refines the two-sub-case families: an `==`/`!=` swap reads
  `:comparison`'s NULL-exclusion note (every other comparison the boundary note), and a `*`/`/`
  swap reads `:arithmetic`'s multiplicative-identity note (a `+`/`-` swap the additive one).
  """
  @spec equivalence_note(family(), Mutation.variant()) :: String.t() | nil
  def equivalence_note(family, finer \\ nil)

  def equivalence_note(:comparison, finer) when finer in ["==", "!="],
    do: @comparison_equality_note

  def equivalence_note(:arithmetic, finer) when finer in ["*", "/"],
    do: @arithmetic_multiplicative_note

  def equivalence_note(family, _finer), do: Map.get(@equivalence_notes, family)

  @doc """
  Enrich a mutant `node` with the metadata its `family` (and optional `finer` label) carry, ready to
  return from `mutate/2` or a host target's `:mutants`. Every mutant is wrapped in a
  `%Mutare.Mutator.Mutation{}`:

    * **`variant:`** — `[family | finer]`, the `# mutare:ignore` labels that suppress this mutant.
      `family` is the per-site analogue of the run-wide `families:` filter
      (`# mutare:ignore[ecto:comparison]`); `finer` is the operator/kind a swap or value family also
      tags (`# mutare:ignore[ecto:<]` — the `<` swap alone), a single label, a list, or absent for a
      structural family. A qualifier matching **any** label suppresses the mutant. The full
      vocabulary is `Mutare.Ecto.variants/0`; labels are recorded only because `Mutare.Ecto` declares
      it (an un-opted-in mutator records `[]`).
    * **`note:`** — the equivalence advisory for a family that has one (`equivalence_note/2`, refined
      for `:comparison` by `finer`), else `nil`. A survivor of an equivalence-sensitive family reads
      "… kill may require …".

  Core accepts the struct on **both** delivery paths (a plain `mutate/2` return and the selector
  host's `:mutants`), so this one wrapper serves every family on either path.
  """
  @spec enrich(family(), Macro.t(), Mutation.variant()) :: Mutation.t()
  def enrich(family, node, finer \\ nil) do
    Mutation.new(node,
      note: equivalence_note(family, finer),
      variant: [family | List.wrap(finer)]
    )
  end

  @doc """
  Split a producer's mutation tag into `{family, node, finer}`. A producer emits either
  `{family, node}` (a structural family — no finer label) or `{family, node, finer}` (a swap/value
  family appending the operator/kind it mutated, for a qualified `# mutare:ignore[ecto:<op>]`). The
  one normalizer both delivery consumers — `Mutare.Ecto.mutate/2` and `Mutare.Ecto.Host.Catalog` —
  feed into `enrich/3`, so adding a finer label to a producer never touches the delivery code.
  """
  @spec split_tag({family(), Macro.t()} | {family(), Macro.t(), Mutation.variant()}) ::
          {family(), Macro.t(), Mutation.variant()}
  def split_tag({family, node}), do: {family, node, nil}
  def split_tag({family, node, finer}), do: {family, node, finer}

  @doc """
  The families enabled by `opts` — the configured `families:` selection, or the **default set**
  (every family except the opt-in `:string_literal`/`:atom_literal`/`:boolean_literal` arms) when it
  is `:default` or unset; `:all` is every family. Raises on an unknown family name, so a typo'd
  `families:` entry fails loudly rather than silently mutating nothing.
  """
  @spec families(keyword() | t()) :: [family()]
  def families(%__MODULE__{families: enabled}),
    do: Enum.filter(all_families(), &MapSet.member?(enabled, &1))

  def families(opts), do: opts |> parse!() |> families()

  # A parsed `%Config{}` unwraps to its family set; every other shape (a `MapSet`, raw options)
  # keeps the generated behaviour.
  @spec family_enabled?(t() | MapSet.t(family()) | keyword(), family()) :: boolean()
  def family_enabled?(%__MODULE__{families: enabled}, family), do: super(enabled, family)
  def family_enabled?(enabled, family), do: super(enabled, family)

  @doc """
  The configured `repo`'s resolved module key (`Mutare.Calls.module_key/1`), ready to compare
  against a `Mutare.Calls.resolved_call/1` module (or to hand to
  `Mutare.Calls.resolved_call_to/3`, which accepts an encoded key), or `nil` when no `repo:` is
  set. Shared by the Repo-call families (`Mutare.Ecto.RepoWrite`, `Mutare.Ecto.RepoAggregate`).
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

  defp validate_option_keys!(opts) do
    case Keyword.keys(opts) -- @valid_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown Mutare.Ecto options: #{inspect(unknown)} — valid options are " <>
                inspect(@valid_options)
    end
  end

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

  defp parse_repo!(nil), do: nil
  defp parse_repo!(module) when is_atom(module), do: Mutare.Calls.module_key(module)

  defp parse_repo!(other) do
    raise ArgumentError, "Mutare.Ecto :repo must be a module atom, got: #{inspect(other)}"
  end
end
