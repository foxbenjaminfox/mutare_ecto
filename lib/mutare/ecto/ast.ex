defmodule Mutare.Ecto.AST do
  @moduledoc false
  # Small AST helpers shared by the Ecto sub-mutators. Only what is genuinely this plugin's lives
  # here: typed literal *readers* (a sub-mutator usually wants "the atom, or nothing", not core's
  # untyped `{:ok, value}`), the top-level-pin check, and the bound-bump arithmetic. Everything a
  # mutator *emits* into existing source comes from core's `Mutare.AST` constructors —
  # `literal/1`, `keyword_key/1`, `clean_var/1`, `absolute_alias/1`/`absolute_call/3`/
  # `remote_call/3` — which own Sourceror's emission invariants (clean/derived meta, numeric
  # `:token`s, string delimiters, the negative-number shape, `Elixir.`-prefixed references).

  @doc "The atom value of an atom literal node (Sourceror-wrapped or bare), or `nil`."
  @spec atom_value(Macro.t()) :: atom() | nil
  def atom_value(node) do
    case Mutare.AST.literal_value(node) do
      {:ok, atom} when is_atom(atom) -> atom
      _other -> nil
    end
  end

  @doc "The integer value of an integer literal node (Sourceror-wrapped or bare), or `nil`."
  @spec int_value(Macro.t()) :: integer() | nil
  def int_value(node) do
    case Mutare.AST.literal_value(node) do
      {:ok, int} when is_integer(int) -> int
      _other -> nil
    end
  end

  @doc """
  The inner list of a list node written bare (`[a, b]`) or inside Sourceror's single-element
  `{:__block__, _, [list]}` wrapper, or `nil` for anything that is not a list. The
  wrapper-preserving inverse is `rewrap_list/2`.
  """
  @spec unwrap_list(Macro.t()) :: [Macro.t()] | nil
  def unwrap_list(node) do
    case Mutare.AST.unwrap_literal(node) do
      list when is_list(list) -> list
      _other -> nil
    end
  end

  @doc """
  Re-wrap `list` in the same Sourceror wrapper `node` carried: a `{:__block__, meta, [_]}` keeps its
  meta, a bare list stays bare. The inverse of `unwrap_list/1`, used to rebuild a normalized list
  without disturbing its written form.
  """
  @spec rewrap_list(Macro.t(), [Macro.t()]) :: Macro.t()
  def rewrap_list({:__block__, meta, [_old]}, list), do: {:__block__, meta, [list]}
  def rewrap_list(_node, list), do: list

  @doc """
  The off-by-one boundary bumps for an integer `limit`/`offset` bound: `n+1` always, and `n-1`
  only when it stays non-negative (a negative bound is invalid SQL). Consumed by the host's
  bound catalog (`Mutare.Ecto.Host.Catalog.bounds/1`), which feeds it `int_value/1` and re-emits
  each result through `Mutare.AST.literal/1` as a branch of the pin-only weave.
  """
  @spec bumps(integer()) :: [integer()]
  def bumps(n) when n > 0, do: [n + 1, n - 1]
  def bumps(n), do: [n + 1]
end
