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

  @doc "Whether `node` is a top-level pin, allowing for Sourceror's block wrapper."
  @spec top_level_pin?(Macro.t()) :: boolean()
  def top_level_pin?({:^, _meta, _args}), do: true
  def top_level_pin?({:__block__, _meta, [inner]}), do: top_level_pin?(inner)
  def top_level_pin?(_node), do: false

  @doc """
  The off-by-one boundary bumps for an integer `limit`/`offset` bound: `n+1` always, and `n-1`
  only when it stays non-negative (a negative bound is invalid SQL). Shared by the whole-`from`
  bound mutator (`Mutare.Ecto.Query`) and the standalone/pipe one (`Mutare.Ecto.Clause`), which
  feed it `int_value/1` and re-emit each result through `Mutare.AST.literal/1`.
  """
  @spec bumps(integer()) :: [integer()]
  def bumps(n) when n > 0, do: [n + 1, n - 1]
  def bumps(n), do: [n + 1]
end
