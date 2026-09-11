defmodule Mutare.Ecto.Changeset.Routing do
  @moduledoc """
  The per-argument routing classifier for the `Ecto.Changeset` pipeline stages the plugin owns
  (`Mutare.Ecto.Changeset.stages/0` — every validator, constraint, and Repo-time hook it can
  drop) — the changeset counterpart of the query classifier `Mutare.Ecto.Host.Routing`. Nothing
  here is hosted; the classifier only holds back from core's families the positions where a
  core swap would be a **crash, not a mutant**, so a run that lists the plugin next to `:all`
  reports no crasher in a changeset stage. The test of each pin is Ecto's own handling of the
  swapped value:

    * A **written field atom** in the field position (`validate_length(cs, :name, …)`,
      `unique_constraint(cs, :email)`) names a column — structural, like `field/2`'s name in a
      query — and routes `:raw`. Core's atom family would swap it for `:mutare`, an unknown field
      Ecto raises on. Anything else in that slot — a field *list*
      (`validate_required(cs, [:name, :email])`), a variable, a `prepare_changes` function — routes
      `:expression`, so a list stays reachable for core's list families.
    * The **option keys** of `validate_number` route per-pair `{:keyword, …}`, which leaves every
      key raw while the values stay `:expression`. Ecto rejects any option it does not know
      (`ArgumentError: unknown option`), so a swapped key raises — every written key is raw, no
      key set is consulted. The bound literal keeps core's off-by-one mutants, and the
      strict/non-strict swap of the key itself is `Mutare.Ecto.ValidationBoundary`'s.
    * `validate_length`'s keys are **not** held back: Ecto reads `count:`/`is:`/`min:`/`max:` and
      ignores anything else, so core's `min:` → `mutare:` is a live mutant — that one bound gone,
      the call otherwise intact — a finer question than the whole-call `:validation_drop` asks.
      Only a **written mode atom** in its `count:` value (`:graphemes`/`:codepoints`/`:bytes`) is
      held back, by a keyed refinement (`[:expression, count: :raw]`): `:mutare` is no mode, and
      Ecto's mode dispatch has no clause for it on a string field (a `CaseClauseError`). A
      computed value stays `:expression`, so core can mutate how the mode is selected. The
      options of every other stage (a constraint's `name:`, a `message:` alone) stay
      `:expression` — an unlisted stage's option set is not the plugin's to assert.

  Which slot is the field position follows the call's **form**, as in the query classifier:
  written directly (`validate_length(cs, :name, …)`) the changeset is the first visible argument
  and the field the second; piped (`cs |> validate_length(:name, …)`) the changeset is the hidden
  `|>` left side (routed `:expression` by core's default, so the upstream pipeline stays mutable)
  and the field is the first visible argument.
  """

  alias Mutare.CallRouting.{ArgumentRoutes, Call}
  alias Mutare.Ecto.AST
  alias Mutare.Ecto.AST.KeywordList

  # The stage that rejects an unknown option key (the moduledoc): every written key routes raw.
  @raw_key_stages [:validate_number]

  # `validate_length`'s mode option: a written atom value there routes `:raw`; its keys stay core's.
  @mode_option :count

  @doc """
  `c:Mutare.CallRouting.route_arguments/2` for a `:routing`-registered `Ecto.Changeset` stage:
  the per-visible-argument `treatments/3` classification, wrapped as `ArgumentRoutes`.
  """
  @spec route_arguments(Call.t(), Mutare.CallRouting.routing_context()) :: ArgumentRoutes.t()
  def route_arguments(%Call{name: name, arguments: args, pipe_mode: pipe_mode} = call, _context) do
    ArgumentRoutes.from_visible(call, treatments(name, args, pipe_mode))
  end

  @doc """
  Per-visible-argument treatment for a changeset stage `name` with visible `args` in
  `pipe_mode`: every position `:expression`, except a written field atom in the field position
  (`:raw`), `validate_number`'s trailing keyword list (`{:keyword, …}`, every key raw), and
  `validate_length`'s when its `count:` value is a written atom (`[:expression, count: :raw]`) —
  the moduledoc.
  """
  @spec treatments(atom(), [Macro.t()], Mutare.Mutator.pipe_mode()) ::
          [Mutare.CallRouting.treatment()]
  def treatments(name, args, pipe_mode) do
    args
    |> Enum.map(fn _arg -> :expression end)
    |> route_field(args, pipe_mode)
    |> route_options(name, args)
  end

  # The field slot: after the changeset when written directly, first when piped. A written atom
  # there is a column name, `:raw`; anything else keeps `:expression`.
  defp route_field(routes, args, pipe_mode) do
    index = field_index(pipe_mode)

    case Enum.at(args, index) do
      nil -> routes
      node -> if AST.atom_value(node), do: List.replace_at(routes, index, :raw), else: routes
    end
  end

  defp field_index(:unpiped), do: 1
  defp field_index(:piped), do: 0

  # A key-rejecting stage's trailing argument, when it is a written keyword list, routes per
  # pair: keys raw (core's per-pair routing), values `:expression`. `validate_length`'s routes by
  # a keyed refinement when a `count:` value is a written atom — that value raw, every key and
  # other value an ordinary expression. The field slot is never the trailing argument of a
  # well-formed call, and a field atom is no keyword list, so a malformed arity keeps the base
  # routing.
  defp route_options(routes, name, args) when name in @raw_key_stages do
    case args |> List.last() |> KeywordList.nonempty() do
      %KeywordList{entries: entries} ->
        List.replace_at(routes, -1, {:keyword, Enum.map(entries, fn _entry -> :expression end)})

      nil ->
        routes
    end
  end

  defp route_options(routes, :validate_length, args) do
    case args |> List.last() |> KeywordList.nonempty() do
      %KeywordList{entries: entries} ->
        if Enum.any?(entries, &written_mode?/1),
          do: List.replace_at(routes, -1, [:expression, {@mode_option, :raw}]),
          else: routes

      nil ->
        routes
    end
  end

  defp route_options(routes, _name, _args), do: routes

  defp written_mode?(%KeywordList.Entry{key: @mode_option, value: value}),
    do: AST.atom_value(value) != nil

  defp written_mode?(_entry), do: false
end
