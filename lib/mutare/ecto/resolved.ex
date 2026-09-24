defmodule Mutare.Ecto.Resolved do
  @moduledoc false
  # Core (Mutare 0.4.0) leaves a `:raw`/`:hosted` argument exactly as written: nothing inside it is
  # resolved or routed — no pipe is desugared, a query macro nested there carries no identity and
  # an author's `:skip` macro no route. The plugin's SQL catalogs read both off the stamps
  # (`Mutare.Ecto.Walk`'s author-macro rule, `Mutare.Ecto.Subquery`'s inline `from`,
  # `Mutare.Ecto.Aggregate`'s ownership rule, `Mutare.Ecto.Fragment`'s nullness), so at its two
  # core boundaries (`Mutare.Ecto.Dispatcher.mutations/2`, `Mutare.Ecto.Host.host/2`) the plugin
  # resolves those regions itself — in the lexical environment core retained at the call for its
  # islands (`context.resolution`, the same one `Mutare.Analyze.expression_mutations/3` resolves
  # an island in), through core's own resolver, so a nested call is stamped exactly as core
  # stamps one in an expression region. A region core has already resolved (`:expression`, an
  # `:interpolated` value) is left alone. A context that carries no environment (a producer
  # driven directly, in a test) leaves the call as it is.

  alias Mutare.Calls
  alias Mutare.Ecto.AST.KeywordList
  alias Mutare.Transform.Resolve

  @doc """
  The routed call `node` with its written regions resolved in `core`'s environment — through
  every registered macro nested inside them, so an inline `from` under `exists(…)` or
  `subquery(…)` is a query call to the catalogs, as it was when core stamped those regions
  itself.
  """
  @spec call(Macro.t(), Mutare.Mutator.context()) :: Macro.t()
  def call({head, meta, args} = node, core) when is_list(args) do
    case Calls.routed_treatments(node) do
      treatments when is_list(treatments) and length(treatments) == length(args) ->
        {head, meta, Enum.zip_with(args, treatments, &argument(&1, &2, core))}

      _skip_or_unrouted ->
        node
    end
  end

  def call(node, _core), do: node

  defp argument(arg, treatment, core) when treatment in [:raw, :hosted],
    do: arg |> Resolve.expression(core) |> nested(core)

  defp argument(arg, {:keyword, treatments}, core) do
    case KeywordList.nonempty(arg) do
      %KeywordList{entries: entries} = list when length(entries) == length(treatments) ->
        treatments
        |> Enum.with_index()
        |> Enum.reduce(list, fn {treatment, index}, list ->
          KeywordList.put_value(
            list,
            index,
            argument(Enum.at(entries, index).value, treatment, core)
          )
        end)
        |> KeywordList.to_ast()

      _other ->
        arg
    end
  end

  defp argument(arg, _core_resolved, _core), do: arg

  # Core's resolver stops at a nested routed call's own written regions, as it does at the
  # top; resolve those too, on the way down.
  defp nested({form, meta, args} = node, core) when is_list(args) do
    case Calls.routed_treatments(node) do
      treatments when is_list(treatments) -> call(node, core)
      :skip -> node
      nil -> {form, meta, Enum.map(args, &nested(&1, core))}
    end
  end

  defp nested({left, right}, core), do: {nested(left, core), nested(right, core)}
  defp nested(list, core) when is_list(list), do: Enum.map(list, &nested(&1, core))
  defp nested(node, _core), do: node
end
