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
  alias Mutare.Ecto.Host.{Bindings, Catalog, Target}

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
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      bindings = Bindings.from(source, %{clauses | entries: Enum.take(entries, index + 1)})
      from_target({entry, index}, bindings, opts)
    end)
  end

  defp from_target({%Entry{key: key, value: condition}, index}, bindings, opts) do
    with [_ | _] <- bindings,
         true <- Surface.from_clause?(key, :hosted),
         [_ | _] = mutants <- Catalog.mutants(condition, bindings, opts) do
      [Target.from_clause(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  defp condition_target(args, opts) do
    with {bindings, condition, index} <- Bindings.hosted_condition(args),
         [_ | _] = mutants <- Catalog.mutants(condition, bindings, opts) do
      [Target.condition(condition, mutants, bindings, index)]
    else
      _ -> []
    end
  end

  defp join_target(args, config) do
    with {arg_index, options} <- trailing_options(args),
         pair_index when not is_nil(pair_index) <-
           Enum.find_index(options.entries, &(&1.key == :on)),
         %Entry{value: condition} = Enum.at(options.entries, pair_index),
         [_ | _] = bindings <- Bindings.join(args),
         [_ | _] = mutants <- Catalog.mutants(condition, bindings, config) do
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
