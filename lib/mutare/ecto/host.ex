defmodule Mutare.Ecto.Host do
  @moduledoc """
  Builds selector-host targets for localized Ecto query conditions.

  The companion `Mutare.Ecto.Host.Routing` identifies hosted argument positions. This module then
  coordinates three focused components: `Host.Bindings` interprets Ecto binding declarations,
  `Host.Catalog` produces logical SQL mutants, and `Host.Target` constructs the `dynamic/2` wrap and
  selector splice consumed by Mutare core.
  """

  alias Mutare.Ecto.{AST, Config, Surface}
  alias Mutare.Ecto.Host.{Bindings, Catalog, Target}

  @condition_macros Surface.condition_macros()
  @hosted_clause_keys Surface.hosted_clause_keys()

  @doc "The selector-host targets for an Ecto.Query macro node."
  @spec host(Macro.t(), Mutare.Mutator.context()) :: [Target.t()]
  def host(node, context) do
    config = Config.from_context(context)

    case AST.query_macro_call(node) do
      {:from, [source, clauses], _rebuild} when is_list(clauses) ->
        from_targets(source, clauses, config)

      {macro, args, _rebuild} when macro in @condition_macros and is_list(args) ->
        condition_target(args, config)

      {:join, args, _rebuild} when is_list(args) ->
        join_target(args, config)

      _ ->
        []
    end
  end

  defp from_targets(source, clauses, opts) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {pair, index} ->
      bindings = Bindings.from(source, Enum.take(clauses, index + 1))
      from_target({pair, index}, bindings, opts)
    end)
  end

  defp from_target({{key, condition}, index}, bindings, opts) do
    with [_ | _] <- bindings,
         true <- AST.atom_value(key) in @hosted_clause_keys,
         [_ | _] = mutants <- Catalog.mutants(condition, bindings, opts) do
      [Target.from_clause(condition, mutants, bindings, index, key)]
    else
      _ -> []
    end
  end

  defp condition_target(args, opts) do
    with index when not is_nil(index) <- Bindings.condition_index(args),
         bindings = Bindings.declarations(Enum.at(args, index - 1)),
         condition = Enum.at(args, index),
         [_ | _] = mutants <- Catalog.mutants(condition, bindings, opts) do
      [Target.condition(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  defp join_target(args, config) do
    with {arg_index, options} <- trailing_options(args),
         pair_index when not is_nil(pair_index) <- Enum.find_index(options, &Bindings.on_pair?/1),
         {_key, condition} = Enum.at(options, pair_index),
         [_ | _] = bindings <- Bindings.join(args),
         [_ | _] = mutants <- Catalog.mutants(condition, bindings, config) do
      [Target.keyword_condition(condition, mutants, bindings, arg_index, pair_index)]
    else
      _ -> []
    end
  end

  defp trailing_options(args) do
    index = length(args) - 1

    case List.last(args) do
      [_ | _] = options -> {index, options}
      _ -> nil
    end
  end
end
