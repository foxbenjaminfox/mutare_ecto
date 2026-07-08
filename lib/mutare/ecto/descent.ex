defmodule Mutare.Ecto.Descent do
  @moduledoc false
  # The author-macro descent rule shared by every structural expression walk in the plugin:
  # `Mutare.Ecto.Fragment` (the SQL catalog's mutation walk **and** its island walk) and
  # `Mutare.Ecto.ExpressionWalk` (the `select`/`order_by` walker).
  #
  # A nested macro the author wrote may invent its own argument grammar — Mutare mutates source,
  # not expansions, and a macro is free to accept arguments that are valid Elixir *tokens* but not
  # standard Ecto syntax. So a call's argument is descended **only** when it is plainly standard
  # syntax: a non-macro node (`nil` routing — an ordinary operator/call/field we own), or an
  # argument the macro routed `:expression` (the one treatment that asserts "a standard expression
  # here, mutate it"). Every other treatment — `:skip`, `:pattern`, `:binding_pattern`, `:hosted`,
  # `:interpolated`, `{:keyword, …}` — marks an argument whose grammar is the macro's own, left raw.
  # The per-argument routing is read from the resolve-pass stamp via `Mutare.Calls.macro_treatment/1`.
  #
  # Homing the rule here keeps the catalog's mutation walk and its island walk provably in agreement
  # about which arguments they enter — a divergence would silently leave a real mutant island
  # uncollected, or treat a pin as SQL the catalog owns. `Mutare.Ecto.FragmentWalkParityTest` guards
  # the structural half of that agreement (`is_nil`/`exists`/list recognition); this module owns the
  # nested-macro half.

  alias Mutare.Calls

  @doc """
  Flat-map `fun.(arg, index)` over every argument of call `node` the descent rule admits, in written
  order. `node` is a `{form, meta, args}` call; `fun` returns a list of results for the argument it
  is given (`[]` to contribute nothing). An argument whose grammar the macro reserves is never
  visited, so `fun` only ever sees standard syntax.
  """
  @spec each_arg(Macro.t(), (Macro.t(), non_neg_integer() -> [term()])) :: [term()]
  def each_arg({_form, _meta, args} = node, fun) when is_list(args) do
    routing = Calls.macro_treatment(node)

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      if descend_arg?(routing, index), do: fun.(arg, index), else: []
    end)
  end

  defp descend_arg?(nil, _index), do: true
  defp descend_arg?(routing, index), do: Enum.at(routing, index) == :expression
end
