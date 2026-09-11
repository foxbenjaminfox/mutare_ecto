defmodule Mutare.Ecto.ValidationBoundary do
  @moduledoc """
  Swap a `validate_number/3` bound between its strict and non-strict form — the changeset twin of
  the in-query `:comparison` swap. `validate_number(:age, greater_than: 0)` →
  `validate_number(:age, greater_than_or_equal_to: 0)`. "Is the bound *itself* tested?" — the two
  validations accept the same values except one exactly on the bound, so the mutant survives
  unless a test builds a changeset whose value sits on it and asserts the verdict. Family
  `:validation_boundary`; equivalence-sensitive (`Mutare.Ecto.Equivalence`), because a kill needs
  exactly that fixture.

  Four swaps, in two pairs: `greater_than` ↔ `greater_than_or_equal_to` and `less_than` ↔
  `less_than_or_equal_to`. `equal_to`/`not_equal_to` are deliberately not swapped: the mutant
  rejects the one value the written validation accepts (or the reverse), which any happy-path test
  kills — no signal beyond the whole-call `:validation_drop`. `validate_length`'s `min`/`max`/`is`
  are inclusive with no strict twin, so the off-by-one there is core's integer family's (the value
  stays an ordinary expression — `Mutare.Ecto.Changeset.Routing`).

  One mutant per swappable option; every other option (`message:`, a second bound) is kept as
  written. Matched like the stage drops (`Mutare.Ecto.Changeset`): the call resolves to
  `Ecto.Changeset` in any spelling, and the options are the trailing argument in the direct and
  piped forms alike. A non-keyword options argument (`validate_number(cs, :age, opts)`) yields
  nothing — there is no written key to swap. Delivered in place (the call rebuilt in its written
  form), reported at and tagged with the **written** key so
  `# mutare:ignore[ecto:greater_than]` on a bound's line suppresses its swap.
  """

  alias Mutare.Calls
  alias Mutare.Ecto.{Context, Tag}
  alias Mutare.Ecto.AST.KeywordList
  alias Mutare.Mutator.Mutation

  @behaviour Mutare.Ecto.SubMutator
  @behaviour Mutare.Ecto.Vocabulary

  @swaps %{
    greater_than: :greater_than_or_equal_to,
    greater_than_or_equal_to: :greater_than,
    less_than: :less_than_or_equal_to,
    less_than_or_equal_to: :less_than
  }

  @doc "The strict/non-strict twin of a `validate_number` option key, or `nil` for any other key."
  @spec swap(atom()) :: atom() | nil
  def swap(key), do: Map.get(@swaps, key)

  @doc """
  The finer `# mutare:ignore` label for a bound swap: the **written** key
  (`# mutare:ignore[ecto:greater_than]` leaves a `greater_than:` bound's swap alone). Total over
  any key; whether a swap exists is `swap/1`'s decision.
  """
  @spec label(atom()) :: String.t()
  def label(key), do: Atom.to_string(key)

  @doc """
  Bound-swap mutations for a `validate_number/3` call as `:validation_boundary` tags, or `[]` for
  any other call, for a call without a written keyword options list, or for options without a
  swappable key.
  """
  @spec mutations(Macro.t(), Context.t()) :: [Tag.t()]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %Context{}) do
    with {:ok, fun, [_ | _] = args, rebuild} <-
           Calls.resolved_call_to(node, Ecto.Changeset, [:validate_number]),
         %KeywordList{} = opts <- args |> List.last() |> KeywordList.nonempty() do
      KeywordList.flat_map(opts, fn entry, index ->
        case swap(entry.key) do
          nil ->
            []

          twin ->
            swapped = opts |> KeywordList.put_key(index, twin) |> KeywordList.to_ast()
            rebuilt = rebuild.(fun, List.replace_at(args, -1, swapped))

            [
              Tag.new(
                :validation_boundary,
                rebuilt,
                label(entry.key),
                Mutation.at(entry.key_node, Mutare.AST.keyword_key(twin))
              )
            ]
        end
      end)
    else
      _ -> []
    end
  end

  # `Mutare.Ecto.Vocabulary`: the label of every swap source.
  @impl Mutare.Ecto.Vocabulary
  def variant_labels, do: @swaps |> Map.keys() |> Enum.map(&label/1)
end
