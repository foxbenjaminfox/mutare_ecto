defmodule Mutare.Ecto.RepoWrite do
  @moduledoc """
  Mutations on the **persisting Repo writes** — `insert`/`update`/`delete`/`insert_or_update`
  and their `!` twins. Two families, both matched by resolving the call's module to the
  configured `repo` (so direct, aliased, and `use Ecto.Repo`-defined forms all match):

    * **`:persistence`** — replace the write with the equivalent *non-persisting*
      `Ecto.Changeset.apply_action/2`, surfacing **untested persistence**:

          Repo.insert(cs)   →   Elixir.Ecto.Changeset.apply_action(Elixir.Ecto.Changeset.change(cs), :insert)
          Repo.delete!(x)   →   x |> Elixir.Ecto.Changeset.change() |> Elixir.Ecto.Changeset.apply_action!(:delete)

      The argument is normalised through `Ecto.Changeset.change/1`, which is **total over both
      shapes** Repo writes accept — a bare struct (`insert`/`delete`) *and* a changeset
      (`update`/`insert_or_update`) — so the rewrite never breaks on the struct case.
      `apply_action` faithfully preserves the `{:ok, struct}` / `{:error, changeset}` shape (and
      `apply_action!` raises `Ecto.InvalidChangesetError`, exactly like `insert!`), so the mutant
      diverges from the real write on **only** the success path: it skips persistence and the
      DB-enforced constraints (`unique_constraint`, `foreign_key_constraint`, …) that fire only on
      the real call. So it survives unless a test drives a *successful* write and asserts a
      persistence consequence (a row present, `id`/timestamps assigned, a constraint violated) —
      a precise, well-defined kill condition. On an *invalid* changeset both return `{:error, cs}`
      identically, so there is no spurious kill there. Excludes `insert_all`/`update_all` (bulk,
      no changeset).

    * **`:on_conflict`** — flip an explicit `on_conflict: :nothing` to `on_conflict: :raise` on an
      `insert`/`insert!` (the only writes that take it). `:nothing` silently skips a conflicting
      row; `:raise` (Ecto's default) makes the conflict raise — so a survivor means no test
      exercises the upsert's conflict path. `:nothing`↔`:raise` is the portable pair: both are
      valid without a `conflict_target` (unlike `:replace_all`, which needs one on Postgres, so it
      is left out — a target-less swap would be a runtime crash, a trivially-killed non-mutant).

  **Pipe-aware.** Piped (`cs |> Repo.insert()`) the changeset is the `|>` left-hand side, so the
  `:persistence` mutant is delivered as a right-nested pipe stage
  (`Elixir.Ecto.Changeset.change() |> Elixir.Ecto.Changeset.apply_action(:insert)`) that Mutare
  splices onto the piped value — `cs |> (change() |> apply_action(:insert))`, which flattens to
  the intended two-stage pipe. The `:on_conflict` swap rebuilds the call in its written form via
  `Mutare.Transform.Calls`, so it is pipe-position-agnostic.
  """

  alias Mutare.Ecto.{AST, Pair, RepoCall}

  @behaviour Mutare.Ecto.SubMutator

  # Alias-proof reference to `Ecto.Changeset`: the metamutant recompiles in the *author's* module,
  # whose aliases we don't control — a bare `Ecto.Changeset` there can be shadowed by a submodule
  # (`defmodule Ecto.Changeset` nested in `Foo` aliases `Ecto`→`Foo.Ecto`) or a plain
  # `alias Foo, as: Ecto`, silently retargeting the call. The `Elixir.`-prefixed alias resolves to
  # the real module unconditionally (same stance as `Mutare.Ecto.StageDrop`'s `Elixir.Function`).
  @changeset AST.absolute_alias([:Ecto, :Changeset])

  # Each persisting write → the `apply_action` function (raising or not) and the action atom it
  # passes. The action mirrors the write; `insert_or_update` chooses insert/update at runtime from
  # the changeset state, and the atom only colours an error changeset's `:action`, so `:insert` is
  # a fine fixed choice for it.
  @writes %{
    insert: {:apply_action, :insert},
    update: {:apply_action, :update},
    delete: {:apply_action, :delete},
    insert_or_update: {:apply_action, :insert},
    insert!: {:apply_action!, :insert},
    update!: {:apply_action!, :update},
    delete!: {:apply_action!, :delete},
    insert_or_update!: {:apply_action!, :insert}
  }

  # Writes that accept an `on_conflict:` option (insert family only).
  @on_conflict_writes ~w(insert insert!)a
  @on_conflict_swaps %{nothing: :raise}

  @doc "RepoWrite mutations for `node` as `{family, node}` pairs, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) :: [{atom(), Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %{pipe_mode: pipe_mode} = context) do
    case RepoCall.resolve(node, context) do
      # mutare:ignore[operand_swap] family order is irrelevant — mutations are consumed as a set
      {fun, args, rebuild} -> persistence(fun, args, pipe_mode) ++ on_conflict(fun, args, rebuild)
      nil -> []
    end
  end

  # mutare:ignore[clause_drop] equivalent — the first clause matches every node given core's `%{opts:, pipe_mode:}` context; this fallback only guards a context missing one of those keys, which core never sends
  def mutations(_node, _context), do: []

  # `:persistence` — replace the write with `apply_action(change(arg), action)`.
  defp persistence(fun, args, pipe_mode) do
    case @writes[fun] do
      nil -> []
      {action_fun, action} -> wrap(apply_action(action_fun, action, args, pipe_mode))
    end
  end

  defp wrap(nil), do: []
  defp wrap(node), do: [{:persistence, node}]

  # Piped: the changeset is the pipe's LHS (not in `args`), so emit a right-nested pipe stage —
  # `change() |> apply_action(action)` — that Mutare splices onto the piped value. Opts are dropped.
  defp apply_action(action_fun, action, _args, :piped) do
    {:|>, [], [changeset(:change, []), changeset(action_fun, [AST.atom_literal(action)])]}
  end

  # Unpiped: the changeset is the first argument; wrap it in `change/1` and pass to `apply_action`.
  # Remaining args (the write's opts) are dropped — a non-persisting stub takes none.
  defp apply_action(action_fun, action, [arg | _opts], :unpiped) do
    changeset(action_fun, [changeset(:change, [arg]), AST.atom_literal(action)])
  end

  defp apply_action(_action_fun, _action, [], :unpiped), do: nil

  defp changeset(fun, args), do: AST.remote_call(@changeset, fun, args)

  # `:on_conflict` — flip `on_conflict: :nothing` → `:raise` in the trailing keyword-list arg,
  # rebuilding the call in its written form. Pipe-agnostic: the opts list is the last visible arg
  # in both forms, and a non-literal/absent `on_conflict` value yields nothing.
  defp on_conflict(fun, args, rebuild) when fun in @on_conflict_writes and args != [] do
    {init, [last]} = Enum.split(args, -1)

    case swap_on_conflict(last) do
      nil -> []
      swapped -> [{:on_conflict, rebuild.(fun, init ++ [swapped])}]
    end
  end

  defp on_conflict(_fun, _args, _rebuild), do: []

  defp swap_on_conflict(list) when is_list(list) do
    case Enum.find_index(list, &on_conflict_pair?/1) do
      nil ->
        nil

      index ->
        pair = Enum.at(list, index)
        swapped = @on_conflict_swaps[AST.atom_value(Pair.value(pair))]
        List.replace_at(list, index, Pair.put_value(pair, AST.atom_literal(swapped)))
    end
  end

  defp swap_on_conflict(_other), do: nil

  # A non-pair short-circuits on the key check (`Pair.key/1` returns `nil`), so `Pair.value/1` is
  # never reached on one — no separate fallback clause is needed.
  defp on_conflict_pair?(pair),
    do:
      Pair.key(pair) == :on_conflict and
        Map.has_key?(@on_conflict_swaps, AST.atom_value(Pair.value(pair)))
end
