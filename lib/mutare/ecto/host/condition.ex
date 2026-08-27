defmodule Mutare.Ecto.Host.Condition do
  @moduledoc false
  # Locates the condition argument a host owns in a condition macro's argument list
  # (`where`/`having`, and the free-standing `dynamic/1,2` that shares their shape). Pure
  # argument-shape parsing: it reports the written binding list preceding the condition but never
  # interprets it — rendering the declarations a woven `dynamic/2` re-declares is
  # `Mutare.Ecto.Host.Bindings`' job. Consumed by `Mutare.Ecto.Host` (the weave — `bindings` go
  # through `Bindings.declarations/1`), `Mutare.Ecto.Host.Routing` (marks `index` `:hosted`), and
  # `Mutare.Ecto.Dynamic` (rebuilds the whole call around `index`).
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
  # as `nil` — its trailing pairs route `{:keyword, …}` instead (`Mutare.Ecto.Host.Routing`).

  alias Mutare.Ecto.Binding
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
  # no binding list (or nothing follows it). The `+ 1` offset lives here, not in callers.
  @spec binding_form([Macro.t()]) :: t() | nil
  defp binding_form(args) do
    with {binding_index, bindings} <- BindingList.find(args),
         index = binding_index + 1,
         # mutare:ignore[relational, conditional] equivalent — loosening/dropping this check just lets an out-of-range index through; Enum.at/2 then returns nil for it, and (as with hostable_bare_condition?/1 below) a nil condition still yields no catalog mutants downstream, so no target is produced either way
         true <- index < length(args) do
      %__MODULE__{node: Enum.at(args, index), index: index, bindings: bindings}
    else
      _ -> nil
    end
  end

  # The trailing argument as a host-owned condition with no binding declarations, or `nil` when it is
  # not a condition to host. The shapes that are *not* a binding-less condition: a list (a binding
  # list like `[u]`, a keyword shorthand like `[active: true]`, or an empty `[]` — none a predicate
  # body) and a bare variable (a degenerate non-condition call). Everything else — a
  # comparison/connective/null/membership expression, or a top-level `^cond` pin (whose interior the
  # host sub-contracts to core), possibly referencing only named bindings — is hosted; the catalog
  # then decides whether there is anything to mutate.
  @spec bindingless_form([Macro.t()]) :: t() | nil
  # mutare:ignore[clause_drop] equivalent — dropping this leaves `Enum.at([], -1)` (nil) as the "condition", and Host.Catalog.mutants/3 (via Fragment.mutants's total catch-all clause) already returns [] for `nil`, so `Host.condition_target/3`'s own `[_ | _] = mutants` guard rejects it downstream regardless
  defp bindingless_form([]), do: nil

  defp bindingless_form(args) do
    index = length(args) - 1
    node = Enum.at(args, index)
    if hostable_bare_condition?(node), do: %__MODULE__{node: node, index: index}, else: nil
  end

  # Every excluded shape here (a list, a bare variable) also reaches `Mutare.Ecto.Fragment.mutants/2`'s
  # own total catch-all clause and yields no catalog mutants there, so `Mutare.Ecto.Host`'s
  # `[_ | _] = mutants` guard rejects it downstream regardless of what this predicate answers —
  # hence the ignore below. A top-level `^cond` pin *is* hosted (its interior is sub-contracted to
  # core), so it is deliberately not excluded.
  defp hostable_bare_condition?(node) do
    # Sourceror wraps a bare list/literal in a single-element `__block__`; unwrap one level so the
    # list check below sees the real shape.
    case Mutare.AST.unwrap_literal(node) do
      list when is_list(list) -> false
      # mutare:ignore[conditional] equivalent — see the comment above
      other -> not Binding.variable?(other)
    end
  end
end
