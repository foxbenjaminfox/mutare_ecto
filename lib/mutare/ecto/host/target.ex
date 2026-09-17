defmodule Mutare.Ecto.Host.Target do
  @moduledoc false
  # Builds the `Mutare.Mutator.MacroHost.Target` values consumed by Mutare core and owns every
  # delivery transform: mapping a logical fragment to its selector branch (the target's `:wrap`),
  # pinning the selector, and splicing it into the original call. The bound-bump targets are
  # **pin-only** (`Mutare.Ecto.Bound`): no `:wrap` (core defaults the branch wrapper to identity,
  # so each branch is a bare integer) and no bindings.
  #
  # ## The root-pin rule: a condition that *is* a pin weaves pin-only
  #
  # Every selector is spliced `^`-pinned, so what a branch must be depends on what Ecto does
  # with the value a pin *in that position* carries — and the two positions differ:
  #
  #   * A pin **inside a predicate** (`p.views > ^min`) is a query parameter, natively and
  #     inside `dynamic/2` alike. So a predicate's branch is `dynamic(bindings, fragment)`: the
  #     one form that can carry SQL structure behind a pin, and behaviour-preserving for every
  #     pin nested in it.
  #   * A pin that **is the whole condition** (`where: ^filters`, `where(q, ^cond)`, a join's
  #     `on: ^cond`) is no parameter: Ecto dispatches on its runtime value
  #     (`Ecto.Query.Builder.Filter.filter!/6`) — a `DynamicExpr` is expanded, a boolean is the
  #     literal condition (`true` adds none at all), a keyword list is a field filter
  #     (`[views: 5]` ⇒ `p.views == ^5`), anything else raises. `dynamic(bindings, ^value)`
  #     would push that pin down into predicate position and demote all but the `DynamicExpr`
  #     to a parameter — in the *original* branch too, so the instrumented baseline itself
  #     would break. Its branch is therefore the pin's bare **interior**: the woven
  #     `^case … do` hands Ecto the same kind of value, in the same position, that the author's
  #     `^interior` did, and Ecto's dispatch is untouched by construction — with no binding
  #     list re-declared, since nothing is wrapped.
  #
  # Which of the two a condition is, this module does not decide: every condition target takes
  # the predicate kind (`:expression` / `:root_pin`) that `Mutare.Ecto.Host.Condition.shape/1`
  # reported, the one classification that also decides whether the host owns the value at all.
  #
  # The logical fragment (the Site's diff, the ignore range) stays the written condition, `^`
  # included; only the branch is unpinned, by `:wrap` — which core applies to the mutant
  # branches, the fallback branch, and a nested host's lowered rebuild alike, so the one choice
  # in `branch/2` covers all three.

  alias Mutare.Ecto.AST.{FromCall, KeywordList, QueryCall}
  alias Mutare.Ecto.Host.Condition
  alias Mutare.Mutator.MacroHost

  @type t :: MacroHost.Target.t()

  @doc """
  A target for one condition in a `from` keyword clause. `bindings` are what an `:expression`'s
  `dynamic/2` re-declares; a `:root_pin` weaves without them.
  """
  @spec from_clause(
          Macro.t(),
          Condition.predicate_kind(),
          [Mutare.Mutator.mutation()],
          [Macro.t()],
          non_neg_integer()
        ) ::
          t()
  def from_clause(original, kind, mutants, bindings, index),
    do: new(original, kind, mutants, bindings, from_clause_splice(index))

  @doc "A target for a standalone or piped condition macro argument (`bindings` as in `from_clause/5`)."
  @spec condition(
          Macro.t(),
          Condition.predicate_kind(),
          [Mutare.Mutator.mutation()],
          [Macro.t()],
          non_neg_integer()
        ) :: t()
  def condition(original, kind, mutants, bindings, index),
    do: new(original, kind, mutants, bindings, argument_splice(index))

  @doc """
  A target nested under one keyword option in a standalone query macro (`bindings` as in
  `from_clause/5`).
  """
  @spec keyword_condition(
          Macro.t(),
          Condition.predicate_kind(),
          [Mutare.Mutator.mutation()],
          [Macro.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def keyword_condition(original, kind, mutants, bindings, arg_index, pair_index) do
    new(original, kind, mutants, bindings, fn node, case_node ->
      %QueryCall{args: args} = call = QueryCall.parse(node)
      options = args |> Enum.at(arg_index) |> KeywordList.parse()

      QueryCall.replace_arg(
        call,
        arg_index,
        options |> KeywordList.put_value(pair_index, pin(case_node)) |> KeywordList.to_ast()
      )
    end)
  end

  @doc "A pin-only target for a `from` bound clause value (`limit:`/`offset:`) — no wrap, no bindings."
  @spec bound_from_clause(Macro.t(), [Mutare.Mutator.mutation()], non_neg_integer()) :: t()
  def bound_from_clause(original, mutants, index),
    do: MacroHost.Target.new(original, mutants, from_clause_splice(index))

  @doc "The pin-only sibling for a standalone/pipe bound argument (`limit(q, 10)` / `q |> offset(5)`)."
  @spec bound_argument(Macro.t(), [Mutare.Mutator.mutation()], non_neg_integer()) :: t()
  def bound_argument(original, mutants, index),
    do: MacroHost.Target.new(original, mutants, argument_splice(index))

  # The splice that pins the selector into a `from` keyword clause's value at `index` — shared by
  # the condition target (`from_clause/5`) and the pin-only bound target (`bound_from_clause/3`);
  # only the `:wrap` differs between them.
  defp from_clause_splice(index) do
    fn node, case_node ->
      %FromCall{} = from = FromCall.parse(node)
      from |> FromCall.replace_clause(index, pin(case_node)) |> FromCall.to_ast()
    end
  end

  # The splice that pins the selector into a positional call argument at `index` — shared by the
  # condition target (`condition/5`) and the pin-only bound target (`bound_argument/3`).
  defp argument_splice(index) do
    fn node, case_node ->
      %QueryCall{} = call = QueryCall.parse(node)
      QueryCall.replace_arg(call, index, pin(case_node))
    end
  end

  defp new(original, kind, mutants, bindings, splice) do
    MacroHost.Target.new(original, mutants, splice, wrap: branch(kind, bindings))
  end

  # The fragment → branch mapping, chosen once per target by the condition's predicate kind (the
  # root-pin rule, in the module header).
  defp branch(:root_pin, _bindings), do: &interior/1

  defp branch(:expression, bindings) do
    fn fragment ->
      Mutare.AST.absolute_call([:Ecto, :Query], :dynamic, [bindings, fragment])
    end
  end

  # Single-clause on purpose. A root pin's every mutant is itself a root pin: the SQL catalog
  # reads a pin as a leaf, so the condition is carried entirely by the island sub-contract, whose
  # rebuild re-pins each mutated interior (`Mutare.Ecto.Fragment.islands/1`). A mutant of any
  # other shape means that invariant broke, and the crash names it — a fallback `dynamic/2`
  # wrap would instead quietly reinstate the demotion this rule exists to prevent.
  defp interior({:^, _meta, [interior]}), do: interior

  defp pin(case_node), do: {:^, [], [case_node]}
end
