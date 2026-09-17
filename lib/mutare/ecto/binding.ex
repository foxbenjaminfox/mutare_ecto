defmodule Mutare.Ecto.Binding do
  @moduledoc false
  # The shared binding-AST vocabulary for Ecto query binding lists — the `[a, b]` / `[post: p]` /
  # `[..., c]` patterns that map names to a query's bindings. The selector host
  # (`Mutare.Ecto.Host`, which re-declares a binding list inside the woven `dynamic`) and the
  # in-place positional reorder (`Mutare.Ecto.BindingReorder`) both build on these primitives, so
  # "what is a binding variable / the `...` anchor / one entry of a declaration" is decided in
  # exactly one place rather than re-derived per module.
  #
  # ## The entry grammar
  #
  # `parse/1` is the one home of the grammar of a **declaration entry**. It mirrors
  # `Ecto.Query.Builder.escape_bind/1` clause for clause, *in Ecto's order* — the order is
  # load-bearing: Ecto reads `{a, b}` with a variable on the left as an indexed positional before
  # it ever considers the named form, so `{p, c}` is "`p` at index `c`", never "`c` named `p`".
  #
  #   * `...`          — `:ellipsis`, the tail anchor
  #   * `p`            — `{:positional, var}`
  #   * `{p, 0}`       — `{:indexed, var, 0}`: a positional at an explicit index
  #   * `post: p`      — `{:named, :post, var}` (also spelled `{:post, p}`)
  #   * `{^name, p}`   — `{:interpolated, name_expr, var}`: a named binding whose name is computed
  #
  # Two of Ecto's forms are read **narrower** than Ecto reads them, because a hosted `dynamic/2`
  # *re-declares* the list next to the original (which keeps its own), so whatever an entry
  # computes is evaluated twice:
  #
  #   * an index must be a literal non-negative integer (Ecto splices any term there);
  #   * an interpolated name must be a variable or a module attribute — the forms that are pure
  #     by construction. `{^next_name(), p}` would run `next_name/0` a second time in the
  #     *unmutated* branch, breaking the one property every mutant scheme rests on (mutant 0 is
  #     the original program).
  #
  # An entry outside the grammar is `:error` — **uninterpretable**, which is a different fact
  # from "not a binding list" and must never be collapsed into "declares nothing"
  # (`Mutare.Ecto.AST.BindingList`, `Mutare.Ecto.Host.Condition`).

  alias Mutare.Ecto.AST

  @typedoc "One parsed declaration entry (see the module comment). `var` nodes keep their written meta."
  @type entry ::
          :ellipsis
          | {:positional, var :: Macro.t()}
          | {:indexed, var :: Macro.t(), index :: non_neg_integer()}
          | {:named, name :: atom(), var :: Macro.t()}
          | {:interpolated, name_expr :: Macro.t(), var :: Macro.t()}

  @doc "A positional binding variable node — `{name, meta, ctx}` with an atom name and hygiene context."
  @spec variable?(Macro.t()) :: boolean()
  # The guard is symmetric with a constant body (so the pattern swap is a no-op), and it only
  # separates a variable from a same-shaped call node — never present in a binding list.
  # mutare:ignore[pattern_swap, logical, conditional] equivalent — see above
  def variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # Flipping the fallback misclassifies a non-variable element as a variable — observable only
  # for a non-binding node a binding position never holds.
  # mutare:ignore[literal] equivalent — see above
  def variable?(_node), do: false

  @doc """
  The name of a **reorderable** entry — a plain positional variable, excluding `_`-prefixed ones —
  or `nil`. Reorderability is narrower than the entry grammar: an indexed entry carries its own
  position (transposing it is a no-op), and a named one is addressed by name.
  """
  @spec reorderable_name(entry()) :: atom() | nil
  def reorderable_name({:positional, {name, _meta, _ctx}}) do
    if name |> Atom.to_string() |> String.starts_with?("_"), do: nil, else: name
  end

  def reorderable_name(_entry), do: nil

  @doc "The `...` tail-anchor node (`[a, ..., c]`) — a leaf with head `:...`; no legal binding shares it."
  @spec ellipsis?(Macro.t()) :: boolean()
  def ellipsis?({:..., _meta, _ctx}), do: true
  def ellipsis?(_node), do: false

  @doc "A fresh clean-meta `...` node, for re-emitting the anchor in a synthesized binding list."
  @spec ellipsis() :: Macro.t()
  def ellipsis, do: {:..., [], []}

  @doc """
  A fresh `_` node — the entry that holds a binding position without naming it (`[p, _, c]`), for
  a synthesized binding list. `parse/1` reads it as an ordinary positional entry, and so does
  Ecto, which lets it repeat (`[p, _, _, c]`) where a repeated name is an error.
  """
  @spec placeholder() :: Macro.t()
  def placeholder, do: {:_, [], nil}

  @doc "Whether an entry occupies a position (rather than addressing a binding by name)."
  @spec positional?(entry()) :: boolean()
  def positional?({:named, _name, _var}), do: false
  def positional?({:interpolated, _name_expr, _var}), do: false
  def positional?(_entry), do: true

  @doc """
  The parsed entry for one element of a binding list (or a lone `lhs` of `lhs in source`), or
  `:error` for a node outside the grammar. `...` is tested before the variable form: on the
  Elixir versions that parse it with an atom context it has a variable's shape.
  """
  @spec parse(Macro.t()) :: {:ok, entry()} | :error
  def parse(node) do
    cond do
      ellipsis?(node) -> {:ok, :ellipsis}
      variable?(node) -> {:ok, {:positional, node}}
      true -> node |> Mutare.AST.unwrap_literal() |> parse_pair()
    end
  end

  # A pair is written bare as a keyword element (`post: p`) and block-wrapped by Sourceror as a
  # tuple literal (`{:post, p}`, `{p, 0}`) — `parse/1` unwraps, so both spellings land here. A
  # variable on the left decides the indexed form *first*, as in Ecto (see the module comment).
  defp parse_pair({left, right}) do
    if variable?(left), do: indexed(left, right), else: keyed(left, right)
  end

  defp parse_pair(_node), do: :error

  defp indexed(var, index_node) do
    case AST.int_value(index_node) do
      index when is_integer(index) and index >= 0 -> {:ok, {:indexed, var, index}}
      _other -> :error
    end
  end

  defp keyed(key, var) do
    cond do
      not variable?(var) -> :error
      name = AST.atom_value(key) -> {:ok, {:named, name, var}}
      name_expr = interpolated_name(key) -> {:ok, {:interpolated, name_expr, var}}
      true -> :error
    end
  end

  # The expression of a `^name` key, when it is one of the forms that are pure by construction
  # (a variable, or a module attribute `@name`), else `nil`.
  defp interpolated_name({:^, _meta, [expr]}), do: if(pure_name?(expr), do: expr, else: nil)
  defp interpolated_name(_key), do: nil

  defp pure_name?({:@, _meta, [attribute]}), do: variable?(attribute)
  defp pure_name?(expr), do: variable?(expr)
end
