defmodule Mutare.Ecto.Tag do
  @moduledoc false
  # The **one** shape every producer emits — sub-mutators (`Mutare.Ecto.SubMutator`) and the
  # shared catalogs (`Mutare.Ecto.Fragment`/`Aggregate`/`Scalar`/`Ordering`) alike: a mutation's
  # SQL `family`, its mutated `node`, and optionally the finer `# mutare:ignore` `label` and a
  # report `attribution`. `to_mutation/1` turns it into the delivered `Mutare.Mutator.Mutation`
  # on every path.
  #
  # Before this struct the contract had drifted to three tuple arities (`{family, node}`,
  # `{family, node, label}`, `{family, node, label, attribution}`), forcing every consumer that
  # bridged two producers to pattern-match all of them — one shape with `nil` defaults deletes
  # those adapters.
  #
  #   * `family` — the SQL family tag (`Mutare.Ecto.Config`'s catalog), the leading variant label
  #     `Mutare.Ecto.Equivalence.finalize/2` reads back for the `families:` filter and the
  #     equivalence note.
  #   * `node` — the mutated AST the delivery path splices/weaves.
  #   * `label` — the finer operator/kind a swap or value family also tags (`"<"`, `"zero"`,
  #     `"sum"`, …) so `# mutare:ignore[ecto:<]` can suppress one swap; a single label, a *list*
  #     when one mutant collapses several kinds (a deduped `0` is both `pred` and `zero`), or
  #     `nil` for a structural family.
  #   * `attribution` — a `Mutare.Mutator.Mutation.at/2`/`at_drop/1` value naming the inner node
  #     the mutant changed — the clause a whole-`from` rewrite changed (`Mutare.Ecto.Query`), or
  #     the expression a walk mutant swapped (`Mutare.Ecto.Walk` anchors every one) — so core
  #     reports the site there rather than at the whole rebuilt form; `nil` for a producer that
  #     rewrites exactly the node it reports (a hosted relay discards it structurally).

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
  mutant, keeping its family/label" step every structural walk and clause rebuilder performs.
  """
  @spec map_node(t(), (Macro.t() -> Macro.t())) :: t()
  def map_node(%__MODULE__{node: node} = tag, fun), do: %{tag | node: fun.(node)}

  @doc """
  The tag as a `Mutare.Mutator.Mutation` carrying its `# mutare:ignore` labels —
  `variant: [family | label]`:

    * `family` is the per-site analogue of the run-wide `families:` filter
      (`# mutare:ignore[ecto:comparison]`) — and the label `Mutare.Ecto.Equivalence.finalize/2`
      reads the family back from.
    * `label` is the operator/kind a swap or value family also tags (`# mutare:ignore[ecto:<]` —
      the `<` swap alone), a single label, a list, or `nil` for a structural family. A qualifier
      matching **any** label suppresses the mutant. The full vocabulary is `Mutare.Ecto.variants/0`;
      labels are recorded only because `Mutare.Ecto` declares it (an un-opted-in mutator records
      `[]`).
    * `attribution` — a `Mutare.Mutator.Mutation.at/2`/`at_drop/1` value naming the inner node
      the mutant changed: carried by a whole-`from` rewrite (`Mutare.Ecto.Query`, the inner
      clause) and by every walk mutant (`Mutare.Ecto.Walk`, the mutated expression itself) —
      makes core report the site (line/column + diff) there rather than at the whole rebuilt
      form, so a clause- or expression-level `# mutare:ignore` is reachable. The mutated `node`
      still splices the whole rewrite; attribution moves only the report, and `finalize/2` reads
      the family off `variant` exactly as for an attribution-less tag.

  The one normalizer both delivery paths return through — `Mutare.Ecto.mutate/2` and the host's
  `Mutare.Ecto.Host.Catalog` — so adding a finer label to a producer never touches delivery code.
  Production stays pure: the `families:` filter and the equivalence note are applied exactly once,
  by core, via `finalize/2`.

  An already-final relayed `Mutation` — explicit `producer:`, a sub-contracted island mutant of a
  free-standing `dynamic` (`Mutare.Ecto.Dynamic`) — passes through untouched: it is a *core*
  family's mutant, carrying core's note and variant, and core's finalize pass bypasses it too.
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
