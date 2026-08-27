defmodule Mutare.Ecto.Host.Condition do
  @moduledoc false
  # The one home of the hosted-condition **shapes**: locates the condition argument a host owns in
  # a condition macro's argument list (`where`/`having`, and the free-standing `dynamic/1,2` that
  # shares their shape). Pure argument-shape parsing: it reports the written binding list
  # preceding the condition but never interprets it — rendering the declarations a woven
  # `dynamic/2` re-declares is `Mutare.Ecto.Host.Bindings`' job. Consumed by `Mutare.Ecto.Host`
  # (the weave — `bindings` go through `Bindings.declarations/1`), `Mutare.Ecto.Host.Routing`
  # (marks `index` `:hosted`), and `Mutare.Ecto.Dynamic` (rebuilds the whole call around `index`).
  #
  # Two shapes resolve here:
  #
  #   * a **binding-form** condition (`where(q, [u], u.x == ^v)`) — the condition sits one slot past
  #     the written binding list, which the woven `dynamic/2` re-declares.
  #   * a **binding-less** condition (`q |> where(as(:post).views > 100)`, `where(q, is_nil(c.x))`) —
  #     no positional list is written, so the condition is the trailing argument and the woven
  #     `dynamic/2` re-declares an **empty** binding list (`dynamic([], …)`). A named-binding
  #     (`as(:_)`), `parent_as`, or `fragment` reference resolves against the query the dynamic is
  #     spliced into, exactly as Ecto's own `where(q, ^dynamic)` form does. This is what lets a
  #     binding-less `where`/`having` still have its SQL operators/literals mutated.
  #
  # Neither shape matches the keyword-shorthand form (`where(q, col: v)`), which `locate/1` reports
  # as `nil` — its trailing pairs route `{:keyword, …}` instead (`Mutare.Ecto.Host.Routing`). A
  # top-level `^cond` pin **is** a condition in either shape: its own SQL catalog is empty, but its
  # interior is sub-contracted to core (`Mutare.Ecto.Island`).

  alias Mutare.Ecto.AST.BindingList

  @enforce_keys [:node, :index]
  defstruct [:node, :index, bindings: nil]

  @typedoc """
  A located host-owned condition: the condition `node`, its argument `index`, and the written
  binding list preceding it — `nil` for the binding-less form, which re-declares an empty one.
  """
  @type t :: %__MODULE__{
          node: Macro.t(),
          index: non_neg_integer(),
          bindings: BindingList.t() | nil
        }

  @doc """
  The host-owned condition argument in `args`, or `nil` when the args carry none (the
  keyword-shorthand form, or nothing to host).
  """
  @spec locate([Macro.t()]) :: t() | nil
  def locate(args) do
    case binding_form(args) do
      %__MODULE__{} = condition -> condition
      nil -> bindingless_form(args)
    end
  end

  # The binding-form condition: one slot past the written binding list, or `nil` when the args carry
  # no binding list — or nothing follows it (a *trailing* binding list is not a condition;
  # `host_test.exs`'s totality case pins that). The `+ 1` offset lives here, not in callers.
  @spec binding_form([Macro.t()]) :: t() | nil
  defp binding_form(args) do
    with {binding_index, bindings} <- BindingList.find(args),
         index = binding_index + 1,
         true <- index < length(args) do
      %__MODULE__{node: Enum.at(args, index), index: index, bindings: bindings}
    else
      _ -> nil
    end
  end

  # The trailing argument as a host-owned condition with no binding declarations, or `nil` when it is
  # not a condition to host: a list (a binding list like `[u]`, a keyword shorthand like
  # `[active: true]`, or an empty `[]` — none a predicate body). Everything else — a
  # comparison/connective/null/membership expression, or a top-level `^cond` pin, possibly
  # referencing only named bindings — is hosted; the catalog then decides whether there is
  # anything to mutate. An argless call (`q |> where()`) has no trailing argument at all, and core
  # still routes it (the macro registers with `:any` arity), so the empty clause keeps this total —
  # `host_test.exs`'s totality case pins it.
  @spec bindingless_form([Macro.t()]) :: t() | nil
  defp bindingless_form([]), do: nil

  defp bindingless_form(args) do
    index = length(args) - 1
    node = Enum.at(args, index)
    if hostable_bare_condition?(node), do: %__MODULE__{node: node, index: index}, else: nil
  end

  # Sourceror wraps a bare list literal in a single-element `__block__`; unwrap one level so the
  # list check sees the real shape. A top-level `^cond` pin *is* hosted (`Mutare.Ecto.Island`), so
  # nothing but a list is excluded.
  defp hostable_bare_condition?(node), do: not is_list(Mutare.AST.unwrap_literal(node))
end
