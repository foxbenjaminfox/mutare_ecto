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
  # `locate/3` finds the predicate a host owns in a condition macro's argument list
  # (`where`/`having`, and the free-standing `dynamic/1,2` that shares their shape), and reads the
  # binding declaration written before it. Consumed by `Mutare.Ecto.Host` (the weave — the
  # declaration goes through `Bindings.declarations/1`, and `kind` picks the delivery),
  # `Mutare.Ecto.Host.Routing` (marks `index` `:hosted`), and `Mutare.Ecto.Dynamic` (rebuilds the
  # whole call around `index`).
  #
  # It also locates the other two places a host-owned predicate sits — a `from`'s condition
  # clauses (`from_indices/1`) and a standalone join's `on:` (`locate_on/1`) — so that the weave
  # (`Mutare.Ecto.Host`) and the whole-call fallback (`Mutare.Ecto.StaticCondition`) enumerate
  # the same conditions and split them by delivery alone. Like `locate/3`, each reports a
  # predicate only, with its kind.
  #
  # ### Located by position, never searched for
  #
  # Both macros end `(…, binding \\ [], expr)`, so the call's **effective arity** says whether a
  # declaration was written, and where: `where(query, binding, expr)` /
  # `query |> where(binding, expr)` carry one in the slot before the condition;
  # `where(query, expr)` / `query |> where(expr)` omit it. (`dynamic` is the same without the
  # threaded query.) The slot is never *searched for* among the arguments — a search can only
  # find a list it already understands, so a declaration it cannot read looks exactly like no
  # declaration at all, and the condition gets hosted behind a `dynamic([], …)` that declares
  # none of the variables it uses. Position keeps the three outcomes apart:
  #
  #   * a **written** declaration the plugin reads — a `BindingList`, the empty `[]` included —
  #     which the woven `dynamic/2` re-declares;
  #   * an **omitted** one (`q |> where(as(:post).views > 100)`, `where(q, is_nil(c.x))`): the
  #     woven `dynamic/2` re-declares an empty list. A named-binding (`as(:_)`), `parent_as`, or
  #     `fragment` reference resolves against the query the dynamic is spliced into, exactly as
  #     Ecto's own `where(q, ^dynamic)` form does — which is what lets a binding-less
  #     `where`/`having` still have its SQL operators/literals mutated;
  #   * an **uninterpretable** one — written, by position, but outside
  #     `Mutare.Ecto.Binding`'s grammar (or hidden on a pipe's left, `[p] |> dynamic(…)`). No
  #     `dynamic/2` can re-declare it, so the condition is rebuilt whole-call under the written
  #     list instead (`Mutare.Ecto.StaticCondition`), as `Mutare.Ecto.Dynamic` rebuilds every
  #     free-standing `dynamic`.
  #
  # Under any of the three, only a predicate is located. A keyword filter, **with or without a
  # binding list before it** (`where(q, col: v)`, `where(q, [p], col: v)`), makes `locate/3`
  # report `nil`, and the trailing pairs route `{:keyword, …}` instead
  # (`Mutare.Ecto.Host.Routing`). A top-level `^cond` pin **is** a predicate, of kind
  # `:root_pin`: its own SQL catalog is empty, but its interior is sub-contracted to core
  # (`Mutare.Ecto.Island`) — and woven pin-only, with no `dynamic/2` and so no re-declared
  # bindings at all (the root-pin rule, `Mutare.Ecto.Host.Target`).

  alias Mutare.Ecto.Surface
  alias Mutare.Ecto.AST.{BindingList, KeywordList}
  alias Mutare.Ecto.AST.KeywordList.Entry
  alias Mutare.Ecto.Host.JoinOn
  alias Mutare.Mutator

  @enforce_keys [:node, :index, :kind, :declaration]
  defstruct [:node, :index, :kind, :declaration]

  @typedoc "The binding declaration preceding a condition — see the module comment's three outcomes."
  @type declaration :: BindingList.t() | :omitted | :uninterpretable

  @typedoc """
  A located host-owned predicate: the condition `node`, its visible argument `index`, its `kind`
  (`shape/1`), and its declaration.
  """
  @type t :: %__MODULE__{
          node: Macro.t(),
          index: non_neg_integer(),
          kind: predicate_kind(),
          declaration: declaration()
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

  @typedoc """
  Which macro's argument layout `locate/3` reads: a query-threading condition macro, or
  `dynamic` (`Mutare.Ecto.Surface`'s macro kinds of those names).
  """
  @type macro_kind :: :condition | :dynamic

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
  The host-owned predicate in the visible `args` of a `macro_kind` macro called under
  `pipe_mode`, or `nil` when the call carries none: a keyword filter (`shape/1`), or an arity
  the macro does not have (an argless `q |> where()` — core still routes it, the macro
  registering with `:any` arity — or a lone `where(q)`; `host_test.exs`'s totality cases pin
  both).
  """
  @spec locate(macro_kind(), [Macro.t()], Mutator.pipe_mode()) :: t() | nil
  def locate(macro_kind, args, pipe_mode) do
    with {declaration_position, condition_position} <-
           layout(macro_kind, Mutator.effective_arity(args, pipe_mode)),
         index when is_integer(index) <- Mutator.visible_index(condition_position, pipe_mode),
         node = Enum.at(args, index),
         {:predicate, kind} <- shape(node) do
      %__MODULE__{
        node: node,
        index: index,
        kind: kind,
        declaration: declaration(declaration_position, args, pipe_mode)
      }
    else
      _ -> nil
    end
  end

  @doc """
  The `from` clauses that hold a host-owned predicate, as a map from each one's index to its
  kind (`shape/1`). A clause qualifies by its key — a `where`/`having`-kind key, or an `on:`
  where `Mutare.Ecto.Host.JoinOn` admits it — and by its value, which must be a predicate: a
  keyword filter under such a key is core's, per pair. A bound (`limit:`/`offset:`) is a
  `:hosted` key too, but it holds a value, not a condition (`Mutare.Ecto.Bound`).
  """
  @spec from_indices(KeywordList.t()) :: %{non_neg_integer() => predicate_kind()}
  def from_indices(%KeywordList{entries: entries}) do
    hostable_on = JoinOn.hostable_from_indices(entries)

    for {%Entry{key: key, value: value}, index} <- Enum.with_index(entries),
        condition_clause?(key, index, hostable_on),
        {:predicate, kind} <- [shape(value)],
        into: %{},
        do: {index, kind}
  end

  defp condition_clause?(:on, index, hostable_on), do: MapSet.member?(hostable_on, index)

  defp condition_clause?(key, _index, _hostable_on),
    do: Surface.from_clause?(key, :hosted) and not Surface.bound?(key)

  @doc """
  The host-owned `on:` predicate of a standalone `join/4,5`, from its visible `args`, as
  `{condition, kind, arg_index, pair_index}` — the predicate and its kind (`shape/1`), where the
  trailing options list sits among the arguments, and where the `on:` pair sits within it — or
  `nil` when the call has no `on:` `Mutare.Ecto.Host.JoinOn` admits, or its `on:` is a keyword
  filter. The options list is the last argument in the direct and piped forms alike.
  """
  @spec locate_on([Macro.t()]) ::
          {Macro.t(), predicate_kind(), non_neg_integer(), non_neg_integer()} | nil
  def locate_on(args) do
    with %KeywordList{entries: entries} <- args |> List.last() |> KeywordList.nonempty(),
         true <- JoinOn.hostable_standalone?(args, entries),
         # `hostable_standalone?/2` admits exactly one `on:`, so the index is found.
         pair_index = Enum.find_index(entries, &(&1.key == :on)),
         %Entry{value: condition} = Enum.at(entries, pair_index),
         {:predicate, kind} <- shape(condition) do
      {condition, kind, length(args) - 1, pair_index}
    else
      _ -> nil
    end
  end

  # The effective positions `{declaration | nil, condition}` of a call of that effective arity.
  # The declaration slot sits right after the arguments that precede it in the macro's head —
  # the threaded query for a condition macro, nothing for `dynamic`.
  defp layout(macro_kind, effective_arity) do
    leading = leading_arguments(macro_kind)

    case effective_arity - leading do
      1 -> {nil, leading}
      2 -> {leading, leading + 1}
      _ -> nil
    end
  end

  defp leading_arguments(:condition), do: 1
  defp leading_arguments(:dynamic), do: 0

  defp declaration(nil, _args, _pipe_mode), do: :omitted

  defp declaration(position, args, pipe_mode) do
    with index when is_integer(index) <- Mutator.visible_index(position, pipe_mode),
         {:ok, list} <- args |> Enum.at(index) |> BindingList.parse() do
      list
    else
      _ -> :uninterpretable
    end
  end
end
