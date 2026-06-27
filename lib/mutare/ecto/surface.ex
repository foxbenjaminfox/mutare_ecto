defmodule Mutare.Ecto.Surface do
  @moduledoc false
  # Canonical metadata for the Ecto.Query surface the plugin classifies. Every consumer derives
  # its macro sets and semantic family from this module so routing, mutation, and stage removal
  # cannot silently drift apart when Ecto adds a builder.

  @condition_macros ~w(where or_where having or_having)a
  @hosted_clause_keys [:on | @condition_macros]
  @ordering_macros ~w(order_by prepend_order_by)a
  @bound_macros ~w(limit offset)a
  @aggregate_macros ~w(select select_merge)a
  @aggregate_query_keys ~w(select select_merge order_by)a

  @clause_macros ~w(
    select select_merge order_by prepend_order_by group_by distinct
    limit offset with_ties join preload lock update with_cte
    windows union union_all except except_all intersect intersect_all
  )a

  @skipped_macros ~w(dynamic is_named_binding)a

  @drop_families @condition_macros
                 |> Map.new(&{&1, :filter_drop})
                 |> Map.merge(Map.new(@bound_macros, &{&1, :bound}))
                 |> Map.merge(Map.new(@clause_macros -- @bound_macros, &{&1, :clause_drop}))

  @doc "The condition builders whose expression is delivered through the selector host."
  @spec condition_macros() :: [atom()]
  def condition_macros, do: @condition_macros

  @doc "`from` clause keys whose SQL condition is selector-hosted."
  @spec hosted_clause_keys() :: [atom()]
  def hosted_clause_keys, do: @hosted_clause_keys

  @doc "The composable query-building macros routed by the plugin."
  @spec clause_macros() :: [atom()]
  def clause_macros, do: @clause_macros

  @doc "The query macros deliberately kept opaque rather than treated as query stages."
  @spec skipped_macros() :: [atom()]
  def skipped_macros, do: @skipped_macros

  @doc "The hosted opener and condition builders."
  @spec hosted_macros() :: [atom()]
  def hosted_macros, do: [:from | @condition_macros]

  @doc "Every macro that returns/builds a query and may contain a nested query argument."
  @spec query_builders() :: [atom()]
  def query_builders, do: [:from | @condition_macros ++ @clause_macros]

  @doc "Clause macros whose final expression carries an ordering."
  @spec ordering_macros() :: [atom()]
  def ordering_macros, do: @ordering_macros

  @doc "Clause macros whose final expression is an integer bound."
  @spec bound_macros() :: [atom()]
  def bound_macros, do: @bound_macros

  @doc "Clause macros whose expression may contain an aggregate call."
  @spec aggregate_macros() :: [atom()]
  def aggregate_macros, do: @aggregate_macros

  @doc "`from` clause keys whose expression may contain an aggregate call."
  @spec aggregate_query_keys() :: [atom()]
  def aggregate_query_keys, do: @aggregate_query_keys

  @doc "The family used when a composable stage is removed, or `nil` when it is not droppable."
  @spec drop_family(atom()) :: :filter_drop | :bound | :clause_drop | nil
  def drop_family(name), do: Map.get(@drop_families, name)
end
