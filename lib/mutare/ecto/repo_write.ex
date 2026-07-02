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

    * **`:on_conflict`** — swap an explicit `on_conflict:` atom on an `insert`/`insert!`/`insert_all`
      (the writes that take the option) for the *distinct* alternative it conflicts-handles to:
      `:nothing`→`:raise` (silent-skip → crash — a survivor means no test exercises the upsert's
      conflict path), `:raise`→`:nothing` (crash → silent-skip — kill with a test asserting a
      duplicate fails), and `:replace_all`→`:nothing` (overwrite-row → keep-old-row — kill with a
      test that asserts the conflicting row was actually overwritten). Every *target* (`:raise`,
      `:nothing`) is valid with no `conflict_target` on all dialects, so each swap is crash-free.
      `:replace_all` is a swap **source** only, never a target — the reverse needs a
      `conflict_target` on Postgres, so a target-less swap would be a runtime crash (a
      trivially-killed non-mutant). Non-atom `on_conflict:` values (a `{:replace, …}` tuple, a
      keyword-list update, a query) are left untouched.

  **Pipe-aware.** Piped (`cs |> Repo.insert()`) the changeset is the `|>` left-hand side, so the
  `:persistence` mutant is delivered as a right-nested pipe stage
  (`Elixir.Ecto.Changeset.change() |> Elixir.Ecto.Changeset.apply_action(:insert)`) that Mutare
  splices onto the piped value — `cs |> (change() |> apply_action(:insert))`, which flattens to
  the intended two-stage pipe. The `:on_conflict` swap rebuilds the call in its written form via
  `Mutare.Calls`, so it is pipe-position-agnostic.
  """

  alias Mutare.Ecto.{AST, RepoCall}
  alias Mutare.Ecto.AST.KeywordList

  use Mutare.Ecto.SubMutator

  # Alias-proof reference to `Ecto.Changeset`: the metamutant recompiles in the *author's* module,
  # whose aliases we don't control — a bare `Ecto.Changeset` there can be shadowed by a submodule
  # (`defmodule Ecto.Changeset` nested in `Foo` aliases `Ecto`→`Foo.Ecto`) or a plain
  # `alias Foo, as: Ecto`, silently retargeting the call. The `Elixir.`-prefixed alias resolves to
  # the real module unconditionally (same stance as `Mutare.Ecto.StageDrop`'s `Elixir.Function`).
  @changeset Mutare.AST.absolute_alias([:Ecto, :Changeset])

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

  # Writes that accept an `on_conflict:` option: the single-row insert family and bulk `insert_all`.
  # (`insert_all` has no `!` twin; `update`/`delete` take no `on_conflict`.)
  @on_conflict_writes ~w(insert insert! insert_all)a

  # Each explicit `on_conflict:` atom → the *distinct* alternative it swaps to. Every target
  # (`:raise`/`:nothing`) is valid with **no** `conflict_target` on all three dialects, so each swap
  # is crash-free regardless of the surrounding opts:
  #
  #   * `:nothing` → `:raise`     — silent-skip → crash. Kill: any test that exercises the conflict path.
  #   * `:raise`   → `:nothing`   — crash → silent-skip. Kill: a test asserting a duplicate insert fails.
  #   * `:replace_all` → `:nothing` — overwrite-row → keep-old-row. Kill: a test inserting a conflicting
  #     row and asserting the columns hold the *new* values.
  #
  # The asymmetry is deliberate: `:replace_all` is a swap **source** only, never a target — the reverse
  # (`:nothing` → `:replace_all`) needs a `conflict_target` on Postgres, so a target-less swap would be
  # a runtime crash (a trivially-killed non-mutant). Non-atom values (`{:replace, …}`, a keyword-list
  # update, a query) read as `nil` via `AST.atom_value` and are skipped.
  @on_conflict_swaps %{nothing: :raise, raise: :nothing, replace_all: :nothing}

  @doc "RepoWrite mutations for `node` as `{family, node}` pairs, or `[]`."
  @spec mutations(Macro.t(), Mutare.Mutator.context()) ::
          [{:persistence | :on_conflict, Macro.t()}]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %{pipe_mode: pipe_mode} = context) do
    case RepoCall.resolve(node, context) do
      # mutare:ignore[operand_swap] family order is irrelevant — mutations are consumed as a set
      {fun, args, rebuild} -> persistence(fun, args, pipe_mode) ++ on_conflict(fun, args, rebuild)
      nil -> []
    end
  end

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
    {:|>, [], [changeset(:change, []), changeset(action_fun, [Mutare.AST.literal(action)])]}
  end

  # Unpiped: the changeset is the first argument; wrap it in `change/1` and pass to `apply_action`.
  # Remaining args (the write's opts) are dropped — a non-persisting stub takes none.
  defp apply_action(action_fun, action, [arg | _opts], :unpiped) do
    changeset(action_fun, [changeset(:change, [arg]), Mutare.AST.literal(action)])
  end

  defp apply_action(_action_fun, _action, [], :unpiped), do: nil

  defp changeset(fun, args), do: Mutare.AST.remote_call(@changeset, fun, args)

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

  # Find the swappable `on_conflict:` pair and flip its value in one pass (`:nothing` → `:raise`),
  # reading the pair's value once. A non-`:on_conflict` pair or an unswappable value yields `nil`
  # (skipped via the `else`, never mistaken for a result), so a list with no such pair returns `nil`.
  defp swap_on_conflict(list) when is_list(list) do
    case KeywordList.parse(list) do
      %KeywordList{entries: entries} = options ->
        Enum.find_value(Enum.with_index(entries), fn {entry, index} ->
          with :on_conflict <- entry.key,
               to when not is_nil(to) <- @on_conflict_swaps[AST.atom_value(entry.value)] do
            KeywordList.replace_value(options, index, Mutare.AST.literal(to))
          else
            _ -> nil
          end
        end)

      nil ->
        nil
    end
  end

  defp swap_on_conflict(_other), do: nil
end
