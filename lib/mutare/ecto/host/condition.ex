defmodule Mutare.Ecto.Host.Condition do
  @moduledoc false
  # The one home of the hosted-condition **shapes** — and, beneath them, of the one
  # classification every condition position is read through (`shape/1`).
  #
  # ## Predicate or keyword filter: decided by the value, never by the key
  #
  # Ecto reads a value written at a condition position (`where`/`having`/`on:`, as a `from`
  # clause, a macro argument, or a join option) one of **three** ways, chosen by the value's
  # written form alone (`Ecto.Query.Builder.Filter.build/6`): a **list literal** goes to the
  # *filter builder*, which turns each `field: value` pair into a field comparison; a **root
  # `^` pin** is dispatched at runtime on the value it carries (a dynamic, a boolean, or a
  # keyword list); everything else — an operator/call expression — goes to the general
  # *expression builder*. The last two are what this module calls a **predicate**, the thing the
  # host owns, and `shape/1` reports which of the two **kinds** it is, because the host delivers
  # them differently. An `:expression` is what the predicate catalog (`Mutare.Ecto.Fragment`)
  # speaks, and the host weaves it behind `dynamic/2`, which *is* the expression builder — it
  # refuses a filter's pairs ("Tuples can only be used in comparisons…") instead of translating
  # them. A `:root_pin`'s interior is Elixir, sub-contracted to core (`Mutare.Ecto.Island`), and
  # the host weaves it pin-only, so Ecto still dispatches on the value the written pin carried
  # (the root-pin rule, `Mutare.Ecto.Host.Target`, which reads the kind from here). A written
  # list is neither.
  #
  # So "this key can hold a condition" (`Mutare.Ecto.Surface`'s `:hosted` capability) is
  # permission to *look* at the value, not to host it; `shape/1` is what decides, and it is the
  # **only** thing that decides — for the classifier (`Mutare.Ecto.Host.Routing` marks a
  # predicate `:hosted` and a filter's pairs `{:keyword, …}`), for the host (`Mutare.Ecto.Host`
  # builds a target for a predicate only) and its whole-call fallback
  # (`Mutare.Ecto.StaticCondition` rebuilds a declined predicate only), and for the subquery
  # recursion (`Mutare.Ecto.Subquery`). Sharing it is load-bearing, not tidiness: core offers
  # the **whole call** to `host/2` as soon as *any* position routed `:hosted` and does not
  # confine the returned targets to those positions, so a host that re-decided on its own would
  # claim a sibling filter the classifier had already given to core, per pair
  # (`from(…, where: [score: 5], limit: 10)`).
  #
  # ## The argument shapes
  #
  # `locate/1` finds the predicate a host owns in a condition macro's argument list
  # (`where`/`having`, and the free-standing `dynamic/1,2` that shares their shape). Pure
  # argument-shape parsing: it reports the written binding list preceding the condition but never
  # interprets it — rendering the declarations a woven `dynamic/2` re-declares is
  # `Mutare.Ecto.Host.Bindings`' job. Consumed by `Mutare.Ecto.Host` (the weave — `bindings` go
  # through `Bindings.declarations/1`, and `kind` picks the delivery), `Mutare.Ecto.Host.Routing`
  # (marks `index` `:hosted`), and `Mutare.Ecto.Dynamic` (rebuilds the whole call around
  # `index`).
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
  # Neither shape matches a keyword filter, **with or without a binding list before it**
  # (`where(q, col: v)`, `where(q, [p], col: v)`): `locate/1` reports `nil`, and the trailing
  # pairs route `{:keyword, …}` instead (`Mutare.Ecto.Host.Routing`). A top-level `^cond` pin
  # **is** a predicate in either shape, of kind `:root_pin`: its own SQL catalog is empty, but its
  # interior is sub-contracted to core (`Mutare.Ecto.Island`) — and woven pin-only, with no
  # `dynamic/2` and so no re-declared bindings at all (the root-pin rule, `Mutare.Ecto.Host.Target`).

  alias Mutare.Ecto.AST.{BindingList, KeywordList}

  @enforce_keys [:node, :index, :kind]
  defstruct [:node, :index, :kind, bindings: nil]

  @typedoc """
  A located host-owned predicate: the condition `node`, its argument `index`, its `kind`
  (`shape/1`), and the written binding list preceding it — `nil` for the binding-less form,
  which re-declares an empty one.
  """
  @type t :: %__MODULE__{
          node: Macro.t(),
          index: non_neg_integer(),
          kind: predicate_kind(),
          bindings: BindingList.t() | nil
        }

  @typedoc """
  What a value written at a condition position is, by how Ecto reads it (the module header's
  first section):

    * `{:predicate, kind}` — the host's to weave, delivered by `kind` (`t:predicate_kind/0`).
    * `{:keyword_filter, pairs}` — a non-empty keyword list, the filter builder's: each pair's
      key names a column, and only its value is data (routed per pair, never hosted).
    * `:pairless_list` — any other list: the empty filter `[]` (Ecto's `true`), or a list the
      keyword reader does not parse (`[{:col, v}]` written as tuples, or a non-filter Ecto
      rejects anyway). Still the filter builder's, so never a predicate — with no pair to route.
  """
  @type shape ::
          {:predicate, predicate_kind()} | {:keyword_filter, KeywordList.t()} | :pairless_list

  @typedoc """
  Which of Ecto's two non-list readings a predicate gets, which decides how the host weaves it
  (the root-pin rule, `Mutare.Ecto.Host.Target`):

    * `:expression` — an operator/call expression, the general expression builder's: woven
      behind `dynamic/2`.
    * `:root_pin` — a `^` pin that is the whole condition (`^cond`, `^[score: 5]`), which Ecto
      dispatches on its runtime value: woven pin-only, over its bare interior. A pin *inside* an
      expression (`p.x > ^v`, `not ^cond`) is a parameter of that expression, so the expression
      is an `:expression`.
  """
  @type predicate_kind :: :expression | :root_pin

  @doc """
  Classify a value written at a condition position (the module header's first section) — the
  single predicate-versus-keyword-filter decision routing and hosting share.
  """
  @spec shape(Macro.t()) :: shape()
  def shape({:^, _meta, [_interior]}), do: {:predicate, :root_pin}

  def shape(value) do
    # Sourceror wraps a bare list literal in a single-element `__block__`; read through it, as
    # Ecto reads the list itself.
    if is_list(Mutare.AST.unwrap_literal(value)),
      do: list_shape(value),
      else: {:predicate, :expression}
  end

  defp list_shape(list) do
    case KeywordList.nonempty(list) do
      %KeywordList{} = pairs -> {:keyword_filter, pairs}
      nil -> :pairless_list
    end
  end

  @doc """
  The host-owned predicate argument in `args`, or `nil` when the args carry none (a keyword
  filter in either form, or nothing to host).
  """
  @spec locate([Macro.t()]) :: t() | nil
  def locate(args) do
    case binding_form(args) do
      %__MODULE__{} = condition -> condition
      nil -> bindingless_form(args)
    end
  end

  # The binding-form condition: one slot past the written binding list, or `nil` when the args carry
  # no binding list, nothing follows it (a *trailing* binding list is not a condition;
  # `host_test.exs`'s totality case pins that), or what follows is not a predicate
  # (`where(q, [p], col: v)` — a binding list only says where a condition *may* sit, exactly as
  # a clause key does). The `+ 1` offset lives here, not in callers.
  @spec binding_form([Macro.t()]) :: t() | nil
  defp binding_form(args) do
    with {binding_index, bindings} <- BindingList.find(args),
         index = binding_index + 1,
         true <- index < length(args),
         node = Enum.at(args, index),
         {:predicate, kind} <- shape(node) do
      %__MODULE__{node: node, index: index, kind: kind, bindings: bindings}
    else
      _ -> nil
    end
  end

  # The trailing argument as a host-owned condition with no binding declarations, or `nil` when it is
  # not a predicate (`shape/1`): a list — a binding list like `[u]`, a keyword filter like
  # `[active: true]`, or an empty `[]`. Everything else — a comparison/connective/null/membership
  # expression, or a top-level `^cond` pin, possibly referencing only named bindings — is hosted;
  # the catalog then decides whether there is anything to mutate. An argless call
  # (`q |> where()`) has no trailing argument at all, and core still routes it (the macro
  # registers with `:any` arity), so the empty clause keeps this total — `host_test.exs`'s
  # totality case pins it.
  @spec bindingless_form([Macro.t()]) :: t() | nil
  defp bindingless_form([]), do: nil

  defp bindingless_form(args) do
    index = length(args) - 1
    node = Enum.at(args, index)

    case shape(node) do
      {:predicate, kind} -> %__MODULE__{node: node, index: index, kind: kind}
      _filter -> nil
    end
  end
end
