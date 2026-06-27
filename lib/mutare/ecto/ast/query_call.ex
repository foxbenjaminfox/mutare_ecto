defmodule Mutare.Ecto.AST.QueryCall do
  @moduledoc false
  # Normalized identity and reconstruction for a resolved Ecto.Query macro call.

  alias Mutare.Ecto.AST
  alias Mutare.Transform.Calls

  @query_key AST.query_module_key()

  @enforce_keys [:node, :name, :args, :rebuild]
  defstruct [:node, :name, :args, :rebuild]

  @type rebuild :: (atom(), [Macro.t()] -> Macro.t())
  @type t :: %__MODULE__{
          node: Macro.t(),
          name: atom(),
          args: [Macro.t()],
          rebuild: rebuild()
        }

  @spec parse(Macro.t()) :: t() | nil
  def parse(node) do
    case Calls.resolved_macro_call(node) do
      {@query_key, name, args, rebuild} ->
        %__MODULE__{node: node, name: name, args: args, rebuild: rebuild}

      _other ->
        nil
    end
  end

  @spec rebuild(t(), [Macro.t()]) :: Macro.t()
  def rebuild(%__MODULE__{name: name, rebuild: rebuild}, args), do: rebuild.(name, args)

  @spec replace_arg(t(), non_neg_integer(), Macro.t()) :: Macro.t()
  def replace_arg(%__MODULE__{args: args} = call, index, value),
    do: rebuild(call, List.replace_at(args, index, value))

  @spec update_arg(t(), non_neg_integer(), (Macro.t() -> Macro.t())) :: Macro.t()
  def update_arg(%__MODULE__{args: args} = call, index, fun),
    do: rebuild(call, List.update_at(args, index, fun))
end
