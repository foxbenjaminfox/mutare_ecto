defmodule Mutare.Ecto.Pair do
  @moduledoc false
  # Accessors for a keyword `{key, value}` pair as it appears in a Sourceror-parsed Ecto clause or
  # option list — a `from` clause (`where: cond`), a query macro's trailing options
  # (`on_conflict: :nothing`, `on: cond`), a join key. The key is an atom literal (Sourceror wraps it
  # as `{:__block__, _, [atom]}`), read through `AST.atom_value/1`; the value is an arbitrary node.
  # Centralizes the "an Ecto clause is a `{key, value}` pair" knowledge that `Mutare.Ecto.Query`,
  # `Mutare.Ecto.RepoWrite`, and the host's `Mutare.Ecto.Host.Target` each re-derived inline.

  alias Mutare.Ecto.AST

  @doc "The pair's key as a bare atom (Sourceror-unwrapped), or `nil` for a non-pair node."
  @spec key(Macro.t()) :: atom() | nil
  def key({key, _value}), do: AST.atom_value(key)

  # mutare:ignore[clause_drop] equivalent — every clause/option list this reads is all `key: value` pairs (Sourceror-parsed), so the non-pair fallback is unreachable from valid Ecto
  def key(_node), do: nil

  @doc "The pair's value node."
  @spec value({Macro.t(), Macro.t()}) :: Macro.t()
  def value({_key, value}), do: value

  @doc "The pair with its value node replaced (the key node is kept verbatim)."
  @spec put_value({Macro.t(), Macro.t()}, Macro.t()) :: {Macro.t(), Macro.t()}
  def put_value({key, _old}, value), do: {key, value}

  @doc "The pair with its key node replaced (the value node is kept verbatim)."
  @spec put_key({Macro.t(), Macro.t()}, Macro.t()) :: {Macro.t(), Macro.t()}
  def put_key({_old, value}, key), do: {key, value}
end
