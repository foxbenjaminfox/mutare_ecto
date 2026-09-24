defmodule Mutare.Ecto.AST.QueryCall do
  @moduledoc false
  # Normalized identity and reconstruction for a resolved Ecto.Query macro call.

  alias Mutare.Calls
  alias Mutare.CallRouting.Call
  alias Mutare.Ecto.AST.KeywordList
  alias Mutare.Transform.{Meta, MetaKeys}

  @enforce_keys [:node, :name, :args, :rebuild]
  defstruct [:node, :name, :args, :rebuild]

  @type rebuild :: (atom(), [Macro.t()] -> Macro.t())
  @type t :: %__MODULE__{
          node: Macro.t(),
          name: atom(),
          args: [Macro.t()],
          rebuild: rebuild()
        }

  @doc """
  The normalized call for `node` if it resolves to an `Ecto.Query` macro, else `nil`. `args` are
  the call's arguments, all of them: core hands a piped stage over as the direct call it is sugar
  for, so `Post |> from(…)` arrives as `from(Post, …)` and the source is argument 0 in both
  spellings. The written pipe is core's to keep in the report.
  """
  @spec parse(Macro.t()) :: t() | nil
  def parse(node) do
    case Calls.resolved_routed_call(node) do
      %Call{module: Ecto.Query, name: name, arguments: args, rebuild: rebuild} ->
        %__MODULE__{node: node, name: name, args: args, rebuild: rebuild}

      _other ->
        nil
    end
  end

  @doc "Rebuild the original call shape (preserving how it was written) with a fresh `args` list."
  @spec rebuild(t(), [Macro.t()]) :: Macro.t()
  def rebuild(%__MODULE__{name: name, rebuild: rebuild}, args),
    do: name |> rebuild.(args) |> unrouted()

  @doc "Rebuild the call under a different macro `name`, keeping the written args and form."
  @spec rename(t(), atom()) :: Macro.t()
  def rename(%__MODULE__{args: args, rebuild: rebuild}, name),
    do: name |> rebuild.(args) |> unrouted()

  # Core's `rebuild` reuses the offered call's meta, its per-argument routing stamp included. A
  # rebuilt call whose keyword argument lost pairs — a `from` with a clause dropped — then
  # carries a `{:keyword, …}` treatment per *original* pair, one too many, and core's binding
  # readers (Mutare 0.4.0's `BindingEscapeEmit`, run over every selector branch) decode the
  # stamp against the rebuilt list and raise. Such a call — always a mutant branch — is handed
  # back without its stamp, which core reads as it reads any call it has none for. Every other
  # rebuilt call keeps its stamp: the host's woven original must, since core's pipe delivery
  # reads the treatment of a piped operand off it (a `:raw` declaration is never bound ahead).
  defp unrouted({head, meta, args} = node) when is_list(meta) do
    if stale_keyword_routing?(Meta.routing(meta), args),
      do: {head, Keyword.delete(meta, MetaKeys.route_key()), args},
      else: node
  end

  defp unrouted(node), do: node

  defp stale_keyword_routing?(treatments, args) when is_list(treatments) do
    length(treatments) != length(args) or
      Enum.zip(args, treatments) |> Enum.any?(fn {arg, t} -> stale_keyword?(arg, t) end)
  end

  defp stale_keyword_routing?(_routing, _args), do: false

  defp stale_keyword?(arg, {:keyword, treatments}) do
    case KeywordList.nonempty(arg) do
      %KeywordList{entries: entries} ->
        length(entries) != length(treatments) or
          entries
          |> Enum.zip(treatments)
          |> Enum.any?(fn {entry, t} -> stale_keyword?(entry.value, t) end)

      nil ->
        false
    end
  end

  defp stale_keyword?(_arg, _treatment), do: false

  @doc "Rebuild the call with `value` substituted for the argument at `index`."
  @spec replace_arg(t(), non_neg_integer(), Macro.t()) :: Macro.t()
  def replace_arg(%__MODULE__{args: args} = call, index, value),
    do: rebuild(call, List.replace_at(args, index, value))
end
