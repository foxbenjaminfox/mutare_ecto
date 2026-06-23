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
