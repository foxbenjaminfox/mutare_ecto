defmodule Mutare.Ecto.JoinType do
  @moduledoc false
  # The shared join-kind swap catalog, used by both delivery forms: the whole-`from` clause-key
  # swap (`Mutare.Ecto.Query`, `left_join: c in …` → `inner_join: c in …`) and the standalone/pipe
  # qualifier swap (`Mutare.Ecto.Clause`, `join(q, :left, …)` → `join(q, :inner, …)`).
  #
  # It is keyed by Ecto's join **qualifier** (`:left`, `:full`, …) — the one name the two
  # spellings share. A standalone `join/3,4,5` writes it as an argument; a `from` writes it into
  # the clause key, `<qualifier>_join:`, which `from_key/1`/`qualifier/1` convert. (`join:` is
  # Ecto's other spelling of `inner_join:`; an inner join is never a flip source, so it needs no
  # entry.)
  #
  # Which flips exist — narrowing only, plus the sideways `left`↔`right` — is a policy with one
  # home, `Mutare.Ecto.Query`'s moduledoc (history in NOTES "JoinType: narrowing only, no
  # introducing swaps"). The gate is about the **target** kind's portability: `left`↔`right`
  # and `full`→`right` need `RIGHT JOIN` (`@right_join_dialects` — SQLite lacks it);
  # `left`→`inner` and `full`→`left` need no gate.

  alias Mutare.Ecto.Config

  @behaviour Mutare.Ecto.Vocabulary

  @portable_flips %{left: [:inner], full: [:left]}
  @right_join_flips %{left: [:right], right: [:left], full: [:right]}
  @right_join_dialects [:postgres, :mysql]

  # Every qualifier a flip reads or writes, and the `from` key that spells each.
  @qualifiers [:inner, :left, :right, :full]
  @from_keys Map.new(@qualifiers, &{&1, :"#{&1}_join"})
  @by_from_key Map.new(@from_keys, fn {qualifier, key} -> {key, qualifier} end)

  @typedoc "A join qualifier the catalog swaps from or to."
  @type qualifier :: :inner | :left | :right | :full

  @doc """
  The qualifiers `qualifier` swaps to under `config`: the portable (narrowing) flips, plus the
  `RIGHT`-capable ones when `config` enables a dialect that supports them. `[]` for a qualifier
  that is never a flip source — `:inner`, `:cross`, the laterals, any non-qualifier.
  """
  @spec targets(atom(), Config.t()) :: [qualifier()]
  def targets(qualifier, %Config{} = config) do
    portable = Map.get(@portable_flips, qualifier, [])

    if Config.dialect_enabled?(config, @right_join_dialects) do
      # mutare:ignore[operand_swap] equivalent — targets are consumed as a set
      portable ++ Map.get(@right_join_flips, qualifier, [])
    else
      portable
    end
  end

  @doc "The qualifier a `from` join key spells (`:left_join` → `:left`), or `nil` for any other key."
  @spec qualifier(atom()) :: qualifier() | nil
  def qualifier(from_key), do: Map.get(@by_from_key, from_key)

  @doc "The `from` join key that spells `qualifier` (`:inner` → `:inner_join`)."
  @spec from_key(qualifier()) :: atom()
  def from_key(qualifier), do: Map.fetch!(@from_keys, qualifier)

  @doc """
  The finer `# mutare:ignore` label for a join swap: the **source** qualifier's name, so
  `# mutare:ignore[ecto:left]` leaves a left join's kind alone in either spelling.
  """
  @spec label(qualifier()) :: String.t()
  def label(qualifier), do: Atom.to_string(qualifier)

  # `Mutare.Ecto.Vocabulary`: each source qualifier, under both flip tables (`left` sits in both,
  # so it repeats — the assembler dedupes).
  @impl Mutare.Ecto.Vocabulary
  def variant_labels do
    [@portable_flips, @right_join_flips]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&label/1)
  end
end
