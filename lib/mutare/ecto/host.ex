defmodule Mutare.Ecto.Host do
  @moduledoc """
  Builds selector-host targets for localized Ecto query conditions.

  The companion `Mutare.Ecto.Host.Routing` identifies hosted argument positions. This module then
  coordinates three focused components: `Host.Bindings` interprets Ecto binding declarations,
  `Host.Catalog` produces logical SQL mutants, and `Host.Target` constructs the `dynamic/2` wrap and
  selector splice consumed by Mutare core.
  """

  alias Mutare.Ecto.{Config, Surface}
  alias Mutare.Ecto.AST.{KeywordList, QueryCall}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.{Bindings, Catalog, JoinOn, Target}

  @doc "The selector-host targets for an Ecto.Query macro node."
  @spec host(Macro.t(), Mutare.Mutator.context()) :: [Target.t()]
  def host(node, context) do
    config = Config.from_context(context)

    case QueryCall.parse(node) do
      %QueryCall{name: :from, args: [source, clauses]} ->
        case KeywordList.parse(clauses) do
          %KeywordList{} = clauses -> from_targets(source, clauses, config)
          nil -> []
        end

      %QueryCall{name: macro, args: args} ->
        case Surface.macro_kind(macro) do
          :condition -> condition_target(args, config)
          :join -> join_target(args, config)
          _other -> []
        end

      _ ->
        []
    end
  end

  defp from_targets(source, %KeywordList{entries: entries} = clauses, opts) do
    hostable_on = JoinOn.hostable_from_indices(entries)
    # Only a binding-list *source* (`[u, v] in q`) writes a transposable positional list; a scalar
    # source (`u in User`) and the join-introduced bindings are synthesized, so they never reorder.
    reorder_names = Bindings.source_positional_names(source)

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      bindings = Bindings.from(source, %{clauses | entries: Enum.take(entries, index + 1)})
      from_target({entry, index}, bindings, reorder_names, opts, hostable_on)
    end)
  end

  defp from_target(
         {%Entry{key: key, value: condition}, index},
         bindings,
         reorder_names,
         opts,
         hostable_on
       ) do
    with true <- hostable_clause?(key, index, hostable_on),
         [_ | _] <- bindings,
         true <- Surface.from_clause?(key, :hosted),
         [_ | _] = mutants <- Catalog.mutants(condition, reorder_names, opts) do
      [Target.from_clause(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  # `where`/`having` always host (each is its own top-level clause). An `on:` hosts only when it is
  # its join's sole, top-level on-expression — otherwise Ecto folds it under an `and` where a
  # `^dynamic` operand is illegal (`Mutare.Ecto.Host.JoinOn`).
  defp hostable_clause?(:on, index, hostable_on), do: MapSet.member?(hostable_on, index)
  defp hostable_clause?(_key, _index, _hostable_on), do: true

  defp condition_target(args, opts) do
    # The binding-list argument of a standalone/pipe `where([u, v], …)` is wholly author-written, so
    # every positional name in it is reorder-eligible.
    with {bindings, condition, index} <- Bindings.hosted_condition(args),
         reorder_names = Bindings.written_positional_names(args),
         [_ | _] = mutants <- Catalog.mutants(condition, reorder_names, opts) do
      [Target.condition(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  defp join_target(args, config) do
    with {arg_index, options} <- trailing_options(args),
         pair_index when not is_nil(pair_index) <-
           Enum.find_index(options.entries, &(&1.key == :on)),
         true <- JoinOn.hostable_standalone?(args, options.entries),
         %Entry{value: condition} = Enum.at(options.entries, pair_index),
         [_ | _] = bindings <- Bindings.join(args),
         # Only the written binding-list arg (`[u, v]`) reorders — never the join-introduced binding.
         reorder_names = Bindings.written_positional_names(args),
         [_ | _] = mutants <- Catalog.mutants(condition, reorder_names, config) do
      [Target.keyword_condition(condition, mutants, bindings, arg_index, pair_index)]
    else
      _ -> []
    end
  end

  defp trailing_options(args) do
    index = length(args) - 1

    case KeywordList.nonempty(List.last(args)) do
      %KeywordList{} = options -> {index, options}
      _ -> nil
    end
  end
end
