defmodule MyApp.QueryHelpers do
  @moduledoc false
  # Author-defined query-helper macros — the surface that proves a nested macro the *author* wrote
  # inside an Ecto `where`/`having` fragment is left opaque when registered `:skip`. The plugin's
  # in-fragment catalogs (`Mutare.Ecto.Fragment`, `Mutare.Ecto.Aggregate`) read that routing via
  # `Mutare.Calls.macro_treatment/1` as they walk the condition, so a `:skip` argument is
  # never mutated into.
  #
  # Each macro only builds operator/aggregate AST that Ecto interprets *where the macro is used*, so
  # no `import Ecto.Query` is needed here — the expansion is spliced into the caller's query position
  # (a real, loadable `defmacro` so a bare `import MyApp.QueryHelpers` resolves it by reflection).

  @doc "An inclusive range check — both bounds are the helper's own (registered fully `:skip`)."
  defmacro between(field, low, high) do
    quote do
      unquote(field) >= unquote(low) and unquote(field) <= unquote(high)
    end
  end

  @doc "Pass the condition through, discarding a trailing label — a *partial* routing fixture."
  defmacro tagged(condition, _label) do
    quote do
      unquote(condition)
    end
  end

  @doc "Wrap an aggregate expression, discarding a trailing bound — for the Aggregate skip test."
  defmacro clamp(expr, _bound) do
    quote do
      unquote(expr)
    end
  end
end

defmodule MyApp.QueryHelperMutator do
  @moduledoc false
  # A routing-providing mutator that registers `MyApp.QueryHelpers`' macros' argument routing — the
  # way a library ships the macro registration its DSL relies on
  # (`c:Mutare.MacroRouting.macro_routes/0`). It produces no mutations of its own (`mutate/1` is
  # always `:skip`); it exists only to teach the transform that these author macros own (some of)
  # their arguments, so `Mutare.Ecto` leaves a `:skip` position raw inside a hosted fragment. Tests
  # add it alongside `{Mutare.Ecto, repo: …}`.
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :query_helpers

  @impl Mutare.MacroRouting
  def macro_routes do
    [
      {MyApp.QueryHelpers, :between, 3, :skip},
      {MyApp.QueryHelpers, :tagged, 2, [:expression, :skip]},
      {MyApp.QueryHelpers, :clamp, 2, :skip}
    ]
  end

  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end
