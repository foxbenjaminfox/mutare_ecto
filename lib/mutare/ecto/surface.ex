defmodule Mutare.Ecto.Surface do
  @moduledoc false
  # One declarative registry for every Ecto.Query macro and `from` clause key the plugin owns.
  # Consumers derive routing, stage removal, hosted conditions, binding accumulation, and mutation
  # capabilities from these descriptors; adding a builder no longer means updating parallel lists.

  @macro_kinds [:from, :condition, :join, :clause, :dynamic, :skip]
  @mutation_capabilities [:ordering, :bound, :aggregate, :arithmetic, :combination]
  @from_capabilities [
    :hosted,
    :ordering,
    :bound,
    :aggregate,
    :arithmetic,
    :join_binding,
    :join_type,
    :combination
  ]
  @drop_families [:filter_drop, :bound, :clause_drop]
  @descriptor_keys [:name, :macro, :mutations, :stage_drop, :from, :from_drop]

  @surface [
    %{name: :from, macro: :from},
    %{
      name: :where,
      macro: :condition,
      stage_drop: :filter_drop,
      from: [:hosted],
      from_drop: :filter_drop
    },
    %{
      name: :or_where,
      macro: :condition,
      stage_drop: :filter_drop,
      from: [:hosted],
      from_drop: :filter_drop
    },
    %{
      name: :having,
      macro: :condition,
      stage_drop: :filter_drop,
      from: [:hosted],
      from_drop: :filter_drop
    },
    %{
      name: :or_having,
      macro: :condition,
      stage_drop: :filter_drop,
      from: [:hosted],
      from_drop: :filter_drop
    },
    %{
      name: :select,
      macro: :clause,
      mutations: [:aggregate, :arithmetic],
      stage_drop: :clause_drop,
      from: [:aggregate, :arithmetic]
    },
    %{
      name: :select_merge,
      macro: :clause,
      mutations: [:aggregate, :arithmetic],
      stage_drop: :clause_drop,
      from: [:aggregate, :arithmetic]
    },
    %{
      name: :order_by,
      macro: :clause,
      mutations: [:ordering, :aggregate, :arithmetic],
      stage_drop: :clause_drop,
      from: [:ordering, :aggregate, :arithmetic]
    },
    %{
      name: :prepend_order_by,
      macro: :clause,
      mutations: [:ordering, :aggregate, :arithmetic],
      stage_drop: :clause_drop
    },
    %{name: :group_by, macro: :clause, stage_drop: :clause_drop},
    %{name: :distinct, macro: :clause, stage_drop: :clause_drop},
    %{
      name: :limit,
      macro: :clause,
      mutations: [:bound],
      stage_drop: :bound,
      from: [:bound],
      from_drop: :bound
    },
    %{
      name: :offset,
      macro: :clause,
      mutations: [:bound],
      stage_drop: :bound,
      from: [:bound],
      from_drop: :bound
    },
    %{name: :with_ties, macro: :clause, stage_drop: :clause_drop},
    %{
      name: :join,
      macro: :join,
      stage_drop: :clause_drop,
      from: [:join_binding, :join_type]
    },
    %{name: :preload, macro: :clause, stage_drop: :clause_drop},
    %{name: :lock, macro: :clause, stage_drop: :clause_drop},
    %{name: :update, macro: :clause, stage_drop: :clause_drop},
    %{name: :with_cte, macro: :clause, stage_drop: :clause_drop},
    %{name: :windows, macro: :clause, stage_drop: :clause_drop},
    %{name: :union, macro: :clause, stage_drop: :clause_drop},
    %{name: :union_all, macro: :clause, stage_drop: :clause_drop},
    %{
      name: :except,
      macro: :clause,
      mutations: [:combination],
      stage_drop: :clause_drop,
      from: [:combination]
    },
    %{
      name: :except_all,
      macro: :clause,
      mutations: [:combination],
      stage_drop: :clause_drop,
      from: [:combination]
    },
    %{
      name: :intersect,
      macro: :clause,
      mutations: [:combination],
      stage_drop: :clause_drop,
      from: [:combination]
    },
    %{
      name: :intersect_all,
      macro: :clause,
      mutations: [:combination],
      stage_drop: :clause_drop,
      from: [:combination]
    },
    %{name: :dynamic, macro: :dynamic},
    %{name: :is_named_binding, macro: :skip},
    %{name: :on, from: [:hosted]},
    %{name: :inner_join, from: [:join_binding, :join_type]},
    %{name: :left_join, from: [:join_binding, :join_type]},
    %{name: :right_join, from: [:join_binding, :join_type]},
    %{name: :full_join, from: [:join_binding, :join_type]},
    %{name: :cross_join, from: [:join_binding]},
    %{name: :inner_lateral_join, from: [:join_binding]},
    %{name: :left_lateral_join, from: [:join_binding]}
  ]

  @names Enum.map(@surface, & &1.name)
  @by_name Map.new(@surface, &{&1.name, &1})

  if length(@names) != MapSet.size(MapSet.new(@names)) do
    raise "Mutare.Ecto.Surface descriptors must have unique names"
  end

  Enum.each(@surface, fn descriptor ->
    unknown_keys = Map.keys(descriptor) -- @descriptor_keys
    macro_kind = Map.get(descriptor, :macro)
    mutations = Map.get(descriptor, :mutations, [])
    from = Map.get(descriptor, :from, [])
    stage_drop = Map.get(descriptor, :stage_drop)
    from_drop = Map.get(descriptor, :from_drop)

    relationships_valid? =
      (mutations == [] or macro_kind == :clause) and
        (is_nil(stage_drop) or macro_kind in [:condition, :join, :clause]) and
        (is_nil(from_drop) or from != []) and
        (macro_kind != :condition or
           (:hosted in from and stage_drop == :filter_drop and from_drop == :filter_drop)) and
        (macro_kind != :join or :join_binding in from)

    unless is_atom(descriptor.name) and unknown_keys == [] and
             (is_nil(macro_kind) or macro_kind in @macro_kinds) and
             mutations -- @mutation_capabilities == [] and from -- @from_capabilities == [] and
             (is_nil(stage_drop) or stage_drop in @drop_families) and
             (is_nil(from_drop) or from_drop in @drop_families) and relationships_valid? do
      raise "invalid Mutare.Ecto.Surface descriptor: #{inspect(descriptor)}"
    end
  end)

  @type macro_kind :: :from | :condition | :join | :clause | :dynamic | :skip
  @type mutation_capability :: :ordering | :bound | :aggregate | :arithmetic | :combination
  @type from_capability ::
          :hosted
          | :ordering
          | :bound
          | :aggregate
          | :arithmetic
          | :join_binding
          | :join_type
          | :combination
  @type drop_family :: :filter_drop | :bound | :clause_drop
  @type descriptor :: %{
          required(:name) => atom(),
          optional(:macro) => macro_kind(),
          optional(:mutations) => [mutation_capability()],
          optional(:stage_drop) => drop_family(),
          optional(:from) => [from_capability()],
          optional(:from_drop) => drop_family()
        }

  @doc "Every registered surface descriptor, in macro-registration order."
  @spec descriptors() :: [descriptor()]
  def descriptors, do: @surface

  @doc "The descriptor for a macro/clause name, or `nil` when the plugin does not own it."
  @spec descriptor(atom()) :: descriptor() | nil
  def descriptor(name), do: Map.get(@by_name, name)

  @doc "The routing kind for a registered query macro, or `nil` for a clause-only/unknown name."
  @spec macro_kind(atom()) :: macro_kind() | nil
  def macro_kind(name), do: get(name, :macro)

  @doc """
  Every Ecto.Query macro registration as `{name, :routing | :skip}`. The `:dynamic` kind registers
  `:skip` like the fully-skipped macros: a free-standing `dynamic/1,2` threads no query and its
  DSL arguments must stay raw for core — but core still offers the *whole call* to `mutate/2`,
  where `Mutare.Ecto.Dynamic` rewrites it in place.
  """
  @spec macro_registrations() :: [{atom(), :routing | :skip}]
  def macro_registrations do
    for %{name: name, macro: kind} <- @surface do
      {name, if(kind in [:dynamic, :skip], do: :skip, else: :routing)}
    end
  end

  @doc """
  Every query macro whose `:routing` classifier can route a position `:hosted` — the `from`
  opener, the `:condition` macros, and `:join`. The plugin subscribes exactly these through
  `c:Mutare.Mutator.MacroHost.hosted_macros/0`.
  """
  @spec hosted_macro_names() :: [atom()]
  def hosted_macro_names do
    for %{name: name, macro: kind} <- @surface, kind in [:from, :condition, :join], do: name
  end

  @doc "Whether `name` is a query-building macro whose nested query should remain reachable."
  @spec query_builder?(atom()) :: boolean()
  def query_builder?(name), do: macro_kind(name) in [:from, :condition, :join, :clause]

  @doc "The standalone mutation capabilities attached to a query macro."
  @spec mutations(atom()) :: [mutation_capability()]
  def mutations(name), do: get(name, :mutations, [])

  @doc """
  Whether a routed macro accepts a written binding list eligible for positional reordering — the
  `:condition` macros (`where`/`having`/…), `:join`, the `:clause` macros, and the free-standing
  `dynamic/2`. Each takes the binding list as an ordinary argument, so the reorder is delivered
  **in place** by `Mutare.Ecto.BindingReorder` (the `from`-level binding-list source reorders at
  the whole-`from` level instead — `Mutare.Ecto.Query`).
  """
  @spec binding_list_macro?(atom()) :: boolean()
  def binding_list_macro?(name), do: macro_kind(name) in [:condition, :join, :clause, :dynamic]

  @doc "The family used when a composable stage is removed, or `nil` when it is not droppable."
  @spec stage_drop_family(atom()) :: drop_family() | nil
  def stage_drop_family(name), do: get(name, :stage_drop)

  @doc "Whether a `from` clause key carries a particular mutation/routing capability."
  @spec from_clause?(atom(), from_capability()) :: boolean()
  def from_clause?(name, capability), do: capability in get(name, :from, [])

  @doc "Every `from` clause key carrying `capability`, in descriptor order."
  @spec from_keys(from_capability()) :: [atom()]
  def from_keys(capability),
    do: for(%{name: name} <- @surface, from_clause?(name, capability), do: name)

  @doc "The family used when a whole-`from` clause is removed, or `nil` when it is retained."
  @spec from_drop_family(atom()) :: drop_family() | nil
  def from_drop_family(name), do: get(name, :from_drop)

  defp get(name, key, default \\ nil) do
    case descriptor(name) do
      nil -> default
      descriptor -> Map.get(descriptor, key, default)
    end
  end
end
