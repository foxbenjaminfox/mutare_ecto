defmodule Mutare.Ecto.AST.QueryCall do
  @moduledoc false
  # Normalized identity and reconstruction for a resolved Ecto.Query macro call.

  alias Mutare.Calls
  alias Mutare.MacroRouting.Call

  @enforce_keys [:node, :name, :args, :pipe_mode, :rebuild]
  defstruct [:node, :name, :args, :pipe_mode, :rebuild]

  @type rebuild :: (atom(), [Macro.t()] -> Macro.t())
  @type t :: %__MODULE__{
          node: Macro.t(),
          name: atom(),
          args: [Macro.t()],
          pipe_mode: Mutare.Mutator.pipe_mode(),
          rebuild: rebuild()
        }

  @doc """
  The normalized call for `node` if it resolves to an `Ecto.Query` macro, else `nil`. `args` are
  the **visible** arguments and `pipe_mode` says whether a hidden `|>` left side precedes them —
  core's stamped identity, so a piped call (`Post |> from(…)`) is a fact of the normalized call,
  not something a consumer re-derives from the node.
  """
  @spec parse(Macro.t()) :: t() | nil
  def parse(node) do
    case Calls.resolved_macro_call(node) do
      %Call{module: Ecto.Query, name: name, arguments: args, pipe_mode: mode, rebuild: rebuild} ->
        %__MODULE__{node: node, name: name, args: args, pipe_mode: mode, rebuild: rebuild}

      _other ->
        nil
    end
  end

  @doc "Rebuild the original call shape (preserving how it was written) with a fresh `args` list."
  @spec rebuild(t(), [Macro.t()]) :: Macro.t()
  def rebuild(%__MODULE__{name: name, rebuild: rebuild}, args), do: rebuild.(name, args)

  @doc "Rebuild the call under a different macro `name`, keeping the written args and form."
  @spec rename(t(), atom()) :: Macro.t()
  def rename(%__MODULE__{args: args, rebuild: rebuild}, name), do: rebuild.(name, args)

  @doc "Rebuild the call with `value` substituted for the argument at `index`."
  @spec replace_arg(t(), non_neg_integer(), Macro.t()) :: Macro.t()
  def replace_arg(%__MODULE__{args: args} = call, index, value),
    do: rebuild(call, List.replace_at(args, index, value))
end
