defmodule Mutare.Ecto.AST do
  @moduledoc false
  # Small AST helpers shared by the Ecto sub-mutators. Only what is genuinely this plugin's lives
  # here: typed literal *readers* (a sub-mutator usually wants "the atom, or nothing", not core's
  # untyped `{:ok, value}`) and the list unwrap/rewrap pair. Everything a
  # mutator *emits* into existing source comes from core's `Mutare.AST` constructors —
  # `literal/1`, `keyword_key/1`, `clean_var/1`, `absolute_alias/1`/`absolute_call/3`/
  # `remote_call/3` — which own Sourceror's emission invariants (clean/derived meta, numeric
  # `:token`s, string delimiters, the negative-number shape). Never hand-build a
  # `{:__block__, meta, [value]}`.
  #
  # Emitted module references are always **`Elixir.`-prefixed** (`absolute_alias/1`/
  # `absolute_call/3`: `Elixir.Ecto.Changeset.apply_action`, `Elixir.Function.identity`). The
  # metamutant recompiles in the *author's* module, whose aliases the plugin doesn't control — a
  # bare `Ecto.Changeset` there can be retargeted by a nested `defmodule Ecto.Changeset` or a
  # plain `alias Foo, as: Ecto`, silently redirecting the call — and only the absolute name
  # resolves unconditionally.

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
end
