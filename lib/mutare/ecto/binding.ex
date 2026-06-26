defmodule Mutare.Ecto.Binding do
  @moduledoc false
  # The shared binding-AST vocabulary for Ecto query binding lists — the `[a, b]` / `[post: p]` /
  # `[..., c]` patterns that map names to a query's bindings by position. The selector host
  # (`Mutare.Ecto.Host`, which re-declares a binding list inside the woven `dynamic`) and the
  # in-place positional reorder (`Mutare.Ecto.BindingReorder`) each build their own list detection
  # and decl handling on these primitives, so "what is a binding variable / the `...` anchor / a
  # block-wrapped list literal" is decided in exactly one place rather than re-derived per module.

  @doc "A positional binding variable node — `{name, meta, ctx}` with an atom name and hygiene context."
  @spec variable?(Macro.t()) :: boolean()
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — symmetric guard with a constant body (swap is a no-op), and the guard only separates a variable from a same-shaped call node, never present in a binding list
  def variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # mutare:ignore[literal] equivalent — flipping the fallback to true misclassifies a non-variable element as a variable, observable only for a non-binding node a binding position never holds
  def variable?(_node), do: false

  @doc "The `...` tail-anchor node (`[a, ..., c]`) — a leaf with head `:...`; no legal binding shares it."
  @spec ellipsis?(Macro.t()) :: boolean()
  def ellipsis?({:..., _meta, _ctx}), do: true
  def ellipsis?(_node), do: false

  @doc "A fresh clean-meta `...` node, for re-emitting the anchor in a synthesized binding list."
  @spec ellipsis() :: Macro.t()
  def ellipsis, do: {:..., [], []}

  @doc """
  The element list of a binding list — unwrapped from the Sourceror block (`{:__block__, _, [list]}`)
  a parsed list literal takes, or a bare list, or `nil` when the node is neither (a lone variable,
  any non-list).
  """
  @spec unwrap_list(Macro.t()) :: [Macro.t()] | nil
  # mutare:ignore[guard_drop] equivalent — Sourceror block-wraps list literals, so this block clause always wraps a list
  def unwrap_list({:__block__, _meta, [list]}) when is_list(list), do: list

  # mutare:ignore[clause_drop, return_value] equivalent — a parsed binding list reaches here block-wrapped (clause above); the bare-list clause guards a non-block list Sourceror-parsed input never produces, and a non-list falls through to the same nil
  def unwrap_list(list) when is_list(list), do: list
  def unwrap_list(_node), do: nil
end
