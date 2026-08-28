defmodule Mutare.Ecto.Tag do
  @moduledoc false
  # The **one** shape every producer emits — sub-mutators (`Mutare.Ecto.SubMutator`) and the
  # shared catalogs (`Mutare.Ecto.Fragment`/`Aggregate`/`Scalar`/`Ordering`) alike
  # (NOTES "Tag: one shape instead of three tuple arities"). `to_mutation/1` turns it into the
  # delivered `Mutare.Mutator.Mutation` on every path.
  #
  #   * `family` — the SQL family tag (`Mutare.Ecto.Config`'s catalog), the leading variant label
  #     `Mutare.Ecto.Equivalence.finalize/2` reads back for the `families:` filter and the
  #     equivalence note.
  #   * `node` — the mutated AST the delivery path splices/weaves.
  #   * `label` — the finer operator/kind a swap or value family also tags (`"<"`, `"zero"`,
  #     `"sum"`, …) so `# mutare:ignore[ecto:<]` can suppress one swap; a single label, a *list*
  #     when one mutant collapses several kinds (a deduped `0` is both `pred` and `zero`), or
  #     `nil` for a structural family. The full vocabulary is `Mutare.Ecto.variants/0`.
  #   * `attribution` — a `Mutare.Mutator.Mutation.at/2`/`at_drop/1` value naming the inner node
  #     the mutant changed — the clause a whole-`from` rewrite changed (`Mutare.Ecto.Query`), or
  #     the expression a walk mutant swapped (`Mutare.Ecto.Walk` anchors every one) — so core
  #     reports the Site there rather than at the whole rebuilt form, while `node` still splices
  #     the whole rewrite; `nil` for a producer that rewrites exactly the node it reports (a
  #     hosted relay discards it structurally).

  alias Mutare.Mutator.Mutation

  @enforce_keys [:family, :node]
  defstruct [:family, :node, label: nil, attribution: nil]

  @type label :: String.t() | [String.t()]
  @type t :: %__MODULE__{
          family: Mutare.Ecto.Config.family(),
          node: Macro.t(),
          label: label() | nil,
          attribution: Mutation.Attribution.t() | nil
        }

  @doc "Build a tag; `label` and `attribution` default to `nil` (a plain structural mutant)."
  @spec new(Mutare.Ecto.Config.family(), Macro.t(), label() | nil, Mutation.Attribution.t() | nil) ::
          t()
  def new(family, node, label \\ nil, attribution \\ nil),
    do: %__MODULE__{family: family, node: node, label: label, attribution: attribution}

  @doc """
  The tag with `fun` applied to its node — the shared "rebuild the surrounding form around each
  mutant, keeping its family/label/attribution" step every structural walk and clause rebuilder
  performs.
  """
  @spec map_node(t(), (Macro.t() -> Macro.t())) :: t()
  def map_node(%__MODULE__{node: node} = tag, fun), do: %{tag | node: fun.(node)}

  @doc """
  The tag as a `Mutare.Mutator.Mutation` carrying its `# mutare:ignore` labels as
  `variant: [family | label]` (a qualifier matching **any** label suppresses the mutant; labels
  are recorded only because `Mutare.Ecto` declares `variants/0`) and its `attribution`. The one
  normalizer both delivery paths return through — `Mutare.Ecto.mutate/2` and
  `Mutare.Ecto.Host.Catalog` — so adding a finer label to a producer never touches delivery code.
  Production stays pure: the `families:` filter and the equivalence note are applied once, by
  core, via `finalize/2` (`Mutare.Ecto.Equivalence`).

  An already-final relayed `Mutation` (explicit `producer:` — a sub-contracted island mutant,
  `Mutare.Ecto.Island`) passes through untouched.
  """
  @spec to_mutation(t() | Mutation.t()) :: Mutation.t()
  def to_mutation(%Mutation{producer: producer} = relayed) when not is_nil(producer), do: relayed

  def to_mutation(%__MODULE__{
        family: family,
        node: node,
        label: label,
        attribution: attribution
      }),
      do: Mutation.new(node, variant: [family | List.wrap(label)], attribution: attribution)
end
