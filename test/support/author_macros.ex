defmodule Mutare.Ecto.AuthorMacros do
  @moduledoc false
  # A routing-only test fixture whose macros deliberately **wear the plugin's own catalog names**.
  #
  # Core's shipped `Mutare.Test.Fixtures.RoutingExtension` covers the general case — a foreign
  # macro whose arguments the catalogs must leave opaque. It cannot cover the *name-collision*
  # case, because its macros (`opaque/1`, `tagged/2`) are named nothing the plugin mutates. This
  # fixture is that case: an author's query DSL is free to define a `sum/2` or a `max/1`, and a
  # catalog that matches on the bare atom would rename it across a ladder its owner never
  # declared — emitting a call that does not exist and failing the whole metamutant build
  # (`Mutare.Ecto.Aggregate.local/2`'s ownership rule).
  #
  # Each macro expands to something valid inside a query, so a fixture using it compiles both
  # before and after mutation, and `assert_compiles/2` is a real net rather than a tautology.

  @behaviour Mutare.CallRouting

  @doc "An author's two-argument `sum` — an arity Ecto's aggregate ladder does not have."
  defmacro sum(a, b), do: quote(do: unquote(a) + unquote(b))

  @doc "An author's one-argument `max` — Ecto's aggregate arity, under a foreign owner."
  defmacro max(x), do: quote(do: unquote(x) * 2)

  @impl Mutare.CallRouting
  def call_routes do
    [
      {__MODULE__, :sum, 2, [:expression, :expression]},
      {__MODULE__, :max, 1, [:expression]}
    ]
  end
end
