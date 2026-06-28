defmodule Mutare.Ecto.AST do
  @moduledoc false
  # Small AST helpers shared by the Ecto sub-mutators. Sourceror wraps every literal in a
  # single-element `{:__block__, meta, [value]}` to anchor its line/token metadata, so reading
  # an atom out of an argument and emitting a fresh one both have to account for that wrapping —
  # and emitting must use **clean meta** (no `:token`), or the renderer re-emits the original
  # text even after the value changed (a silent equivalent no-op; see Mutare's NOTES).

  @query_module_key Ecto.Query |> Module.split() |> Enum.map(&String.to_atom/1)

  @doc """
  The resolved-call/macro module key `Mutare.Transform.Calls` stamps on an `Ecto.Query` call
  (`[:Ecto, :Query]`) — the single source of truth shared by every family that matches a query
  function or macro (`Mutare.Ecto.ClauseDrop`, `Mutare.Ecto.QueryTerminal`,
  `Mutare.Ecto.Host.Routing`), so the split form is never re-derived per module.
  """
  @spec query_module_key() :: [atom()]
  def query_module_key, do: @query_module_key

  @doc "The atom value of an atom literal node (Sourceror-wrapped or bare), or `nil`."
  @spec atom_value(Macro.t()) :: atom() | nil
  def atom_value({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  def atom_value(atom) when is_atom(atom), do: atom
  def atom_value(_node), do: nil

  @doc "A fresh atom literal node, clean-meta so it renders the new value."
  @spec atom_literal(atom()) :: Macro.t()
  # mutare:ignore[guard_drop] equivalent — defensive constructor guard; every caller passes an atom (a non-atom would be an invalid literal here), so no reachable input distinguishes the guarded clause from the bare one
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

  # mutare:ignore[guard_drop] equivalent — constructor guard; every caller passes an integer (the prior clause handles negatives, this one the non-negative rest), so no reachable input distinguishes the guarded clause from a bare one
  def int_literal(int) when is_integer(int),
    do: {:__block__, [token: Integer.to_string(int)], [int]}

  @doc """
  A fresh float literal node that renders the new value. Like `int_literal/1` it carries a
  `:token` (the float's source text) so the formatter has a form to re-emit in an embedded query
  position, and represents a negative float as the canonical unary-minus-over-literal shape
  (`{:-, [], [1.5]}` for `-1.5`), matching how Elixir and `Mutare.AST.literal/1` render it.
  """
  @spec float_literal(float()) :: Macro.t()
  def float_literal(f) when is_float(f) and f < 0, do: {:-, [], [float_literal(-f)]}

  # mutare:ignore[guard_drop] equivalent — constructor guard; every caller passes a float (the prior clause handles negatives, this one the non-negative rest), so no reachable input distinguishes the guarded clause from a bare one
  def float_literal(f) when is_float(f),
    do: {:__block__, [token: Float.to_string(f)], [f]}

  @doc """
  A fresh string literal node that renders the new value, carrying the `delimiter` meta (`"`) the
  formatter needs to re-emit it as a quoted string in an embedded query position — the same
  representation core's `Mutare.AST.literal/1` uses for a binary.
  """
  @spec string_literal(String.t()) :: Macro.t()
  # mutare:ignore[guard_drop] equivalent — defensive constructor guard; every caller passes a binary, so no reachable input distinguishes the guarded clause from a bare one
  def string_literal(s) when is_binary(s), do: {:__block__, [delimiter: ~s(")], [s]}

  @doc """
  The off-by-one boundary bumps for an integer `limit`/`offset` bound: `n+1` always, and `n-1`
  only when it stays non-negative (a negative bound is invalid SQL). Shared by the whole-`from`
  bound mutator (`Mutare.Ecto.Query`) and the standalone/pipe one (`Mutare.Ecto.Clause`), which
  feed it `int_value/1` and re-emit each result through `int_literal/1`.
  """
  @spec bumps(integer()) :: [integer()]
  def bumps(n) when n > 0, do: [n + 1, n - 1]
  def bumps(n), do: [n + 1]

  @doc "A fresh keyword-list **key** node (`format: :keyword`), so it renders as `key:`."
  @spec keyword_key(atom()) :: Macro.t()
  # mutare:ignore[guard_drop] equivalent — defensive constructor guard; a keyword key is always an atom, so dropping the guard changes nothing any caller reaches
  def keyword_key(atom) when is_atom(atom), do: {:__block__, [format: :keyword], [atom]}

  @doc """
  Strip a variable node's metadata, keeping its name and hygiene context — for re-declaring a
  query binding inside a synthesized `dynamic([…], _)` wrap, where the source line/column and any
  Sourceror token meta are irrelevant (the wrap is invisible in the recorded Site).
  """
  @spec clean_var(Macro.t()) :: Macro.t()
  # mutare:ignore[conditional, logical] equivalent — clean_var only ever re-declares a binding *variable* (atom name, atom context); a non-variable 3-tuple never reaches it, so widening the guard to `or`/`true` admits no input that actually occurs
  def clean_var({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: {name, [], ctx}

  @doc """
  Normalize a module reference to the resolved key shape `Mutare.Transform.Calls` returns:
  an Elixir-module alias atom (`MyApp.Repo`) → its segment path (`[:MyApp, :Repo]`), an
  Erlang atom module (`:binary`) → itself. Lets a configured Repo be compared directly to a
  `resolved_call/1` module.
  """
  @spec module_key(module()) :: [atom()] | atom()
  # mutare:ignore[guard_drop] equivalent — a non-atom raises FunctionClauseError here *and*, with the guard dropped, inside Macro.classify_atom/1 just below, so the guarded and unguarded clauses are indistinguishable on every input
  def module_key(module) when is_atom(module) do
    case Macro.classify_atom(module) do
      :alias -> module |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> module
    end
  end

  @doc """
  An `Elixir.`-anchored module alias node for `segments` — `[:Ecto, :Changeset]` →
  `{:__aliases__, [], [:"Elixir", :Ecto, :Changeset]}`. The `Elixir.` prefix makes the reference
  **alias-proof**: the metamutant recompiles in the author's aliasing scope, where a bare
  `Ecto.Changeset` could be retargeted by an `alias`, but the absolute name resolves
  unconditionally (see CLAUDE.md, "Emitted module references are `Elixir.`-prefixed").
  """
  @spec absolute_alias([atom()]) :: Macro.t()
  def absolute_alias(segments), do: {:__aliases__, [], [:"Elixir" | segments]}

  @doc """
  A remote-call node `mod.fun(args)`, where `mod` is an alias node (typically from
  `absolute_alias/1`) — e.g. `Elixir.Function.identity()` or `Elixir.Ecto.Query.dynamic(b, f)`.
  """
  @spec remote_call(Macro.t(), atom(), [Macro.t()]) :: Macro.t()
  def remote_call(mod, fun, args), do: {{:., [], [mod, fun]}, [], args}
end
