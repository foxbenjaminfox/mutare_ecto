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

  @doc "The hosted condition macros (`where`/`having` family), registered `:routing` by the plugin."
  @spec condition_macros() :: [atom()]
  defdelegate condition_macros, to: Surface

  @doc "The plain composable clause macros (`limit`/`order_by`/…), registered `:routing` by the plugin."
  @spec clause_macros() :: [atom()]
  defdelegate clause_macros, to: Surface

  @doc "The selector-host targets for an Ecto.Query macro node."
  @spec host(Macro.t(), Mutare.Mutator.context()) :: [Target.t()]
  def host(node, context) do
    config = Config.from_context(context)

    case AST.query_macro_call(node) do
      {:from, [source, clauses], _rebuild} when is_list(clauses) ->
        from_targets(source, clauses, config)

      {macro, args, _rebuild} when macro in @condition_macros and is_list(args) ->
        condition_target(args, config)

      _ ->
        []
    end
  end

  defp from_targets(source, clauses, opts) do
    case Bindings.from(source, clauses) do
      [] ->
        []

      bindings ->
        clauses
        |> Enum.with_index()
        |> Enum.flat_map(&from_target(&1, bindings, opts))
    end
  end

  defp from_target({{key, condition}, index}, bindings, opts) do
    with true <- AST.atom_value(key) in @condition_macros,
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
end
