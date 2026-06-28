defmodule Mutare.Ecto.Binding do
  @moduledoc false
  # The shared binding-AST vocabulary for Ecto query binding lists — the `[a, b]` / `[post: p]` /
  # `[..., c]` patterns that map names to a query's bindings by position. The selector host
  # (`Mutare.Ecto.Host`, which re-declares a binding list inside the woven `dynamic`) and the
  # in-place positional reorder (`Mutare.Ecto.BindingReorder`) each build their own list detection
  # and decl handling on these primitives, so "what is a binding variable / the `...` anchor / a
  # block-wrapped list literal" is decided in exactly one place rather than re-derived per module.

  alias Mutare.Ecto.AST

  @doc "A positional binding variable node — `{name, meta, ctx}` with an atom name and hygiene context."
  @spec variable?(Macro.t()) :: boolean()
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard with a constant body (swap is a no-op), and the guard only separates a variable from a same-shaped call node, never present in a binding list
  def variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # mutare:ignore[literal] equivalent — flipping the fallback to true misclassifies a non-variable element as a variable, observable only for a non-binding node a binding position never holds
  def variable?(_node), do: false

  @doc "The name of a reorderable positional binding, excluding `_`-prefixed variables."
  @spec reorderable_name(Macro.t()) :: atom() | nil
  def reorderable_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    if name |> Atom.to_string() |> String.starts_with?("_"), do: nil, else: name
  end

  def reorderable_name(_node), do: nil

  @doc "The `...` tail-anchor node (`[a, ..., c]`) — a leaf with head `:...`; no legal binding shares it."
  @spec ellipsis?(Macro.t()) :: boolean()
  def ellipsis?({:..., _meta, _ctx}), do: true
  def ellipsis?(_node), do: false

  @doc "Whether a node is a positional, named, or ellipsis binding-list entry."
  @spec entry?(Macro.t()) :: boolean()
  def entry?({key, var}), do: not is_nil(AST.atom_value(key)) and variable?(var)
  def entry?(node), do: variable?(node) or ellipsis?(node)

  @doc "A fresh clean-meta `...` node, for re-emitting the anchor in a synthesized binding list."
  @spec ellipsis() :: Macro.t()
  def ellipsis, do: {:..., [], []}
end
