defmodule Mutare.Ecto.AST do
  @moduledoc false
  # Small AST helpers shared by the Ecto sub-mutators. Sourceror wraps every literal in a
  # single-element `{:__block__, meta, [value]}` to anchor its line/token metadata, so reading
  # an atom out of an argument and emitting a fresh one both have to account for that wrapping —
  # and emitting must use **clean meta** (no `:token`), or the renderer re-emits the original
  # text even after the value changed (a silent equivalent no-op; see Mutare's NOTES).

  @doc "The atom value of an atom literal node (Sourceror-wrapped or bare), or `nil`."
  @spec atom_value(Macro.t()) :: atom() | nil
  def atom_value({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  def atom_value(atom) when is_atom(atom), do: atom
  def atom_value(_node), do: nil

  @doc "A fresh atom literal node, clean-meta so it renders the new value."
  @spec atom_literal(atom()) :: Macro.t()
  def atom_literal(atom) when is_atom(atom), do: {:__block__, [], [atom]}

  @doc "The integer value of an integer literal node (Sourceror-wrapped or bare), or `nil`."
  @spec int_value(Macro.t()) :: integer() | nil
  def int_value({:__block__, _meta, [int]}) when is_integer(int), do: int
  def int_value(int) when is_integer(int), do: int
  def int_value(_node), do: nil

  @doc """
  A fresh integer literal node that renders the new value. Carries a `:token` (the integer's
  text) because Elixir's formatter fetches it for every integer literal — unlike an atom, a
  clean-meta integer block raises when Sourceror can't synthesize one in an embedded position.
  A negative integer is the canonical unary-minus-over-literal shape (`{:-, [], [5]}` for `-5`),
  matching how Elixir and `Mutare.AST.literal/1` represent it — so it renders and recompiles.
  """
  @spec int_literal(integer()) :: Macro.t()
  def int_literal(int) when is_integer(int) and int < 0, do: {:-, [], [int_literal(-int)]}

  def int_literal(int) when is_integer(int),
    do: {:__block__, [token: Integer.to_string(int)], [int]}

  @doc "A fresh keyword-list **key** node (`format: :keyword`), so it renders as `key:`."
  @spec keyword_key(atom()) :: Macro.t()
  def keyword_key(atom) when is_atom(atom), do: {:__block__, [format: :keyword], [atom]}

  @doc """
  Strip a variable node's metadata, keeping its name and hygiene context — for re-declaring a
  query binding inside a synthesized `dynamic([…], _)` wrap, where the source line/column and any
  Sourceror token meta are irrelevant (the wrap is invisible in the recorded Site).
  """
  @spec clean_var(Macro.t()) :: Macro.t()
  def clean_var({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: {name, [], ctx}

  @doc """
  Whether `name` appears as a binding *variable* node (`{name, _meta, ctx}` with an atom hygiene
  context) anywhere in `ast` — used to gate a binding reorder on the bindings it swaps actually
  being referenced. A field name, atom, or pinned value that merely shares the spelling is not a
  variable node, so it does not count.
  """
  @spec references_var?(Macro.t(), atom()) :: boolean()
  def references_var?(ast, name) when is_atom(name) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {^name, _meta, ctx} = node, _acc when is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  @doc """
  Normalize a module reference to the resolved key shape `Mutare.Transform.Calls` returns:
  an Elixir-module alias atom (`MyApp.Repo`) → its segment path (`[:MyApp, :Repo]`), an
  Erlang atom module (`:binary`) → itself. Lets a configured Repo be compared directly to a
  `resolved_call/1` module.
  """
  @spec module_key(module()) :: [atom()] | atom()
  def module_key(module) when is_atom(module) do
    case Macro.classify_atom(module) do
      :alias -> module |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> module
    end
  end
end
