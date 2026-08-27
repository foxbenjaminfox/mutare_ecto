defmodule Mutare.Ecto.Vocabulary do
  @moduledoc false
  # The contract a producer implements to contribute its finer `# mutare:ignore` labels — the
  # operators/kinds a swap or value family tags beyond its family name (`"<"`, `"zero"`, `"sum"`,
  # `"asc"`, `"left"`, `"intersect"`) — to the plugin's variant vocabulary. `Mutare.Ecto.variants/0`
  # iterates every implementer, so each label is declared where it is emitted (derived from the
  # same swap/flip table the producer mutates along, so the vocabulary can't drift from what is
  # produced) and the vocabulary is assembled in exactly one place.
  #
  # Order and duplicates are the assembler's concern, not the implementer's: `Map.keys` iteration
  # order over an atom-keyed table is unspecified (it varies with runtime atom-table state), and
  # two tables can share a source (`left_join` sits in both join-flip tables), so an
  # implementation returns its labels raw — whatever order and repetition its tables yield — and
  # `Mutare.Ecto.variants/0` dedupes and sorts the union once.

  @doc "The finer `# mutare:ignore` labels this producer can emit — any order, repeats allowed."
  @callback variant_labels() :: [String.t()]
end
