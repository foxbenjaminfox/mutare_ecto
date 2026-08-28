defmodule Mutare.Ecto.RepoWrite do
  @moduledoc """
  Mutations on the **persisting Repo writes** — `insert`/`update`/`delete`/`insert_or_update`
  and their `!` twins. Two families, both matched by resolving the call's module to the
  configured `repo` (so direct, aliased, and `use Ecto.Repo`-defined forms all match):

    * **`:persistence`** — replace the write with the equivalent *non-persisting*
      `Ecto.Changeset.apply_action/2`, surfacing **untested persistence**:

          Repo.insert(cs)
          →
          Elixir.Ecto.Changeset.apply_action(
            Elixir.Map.replace!(Elixir.Ecto.Changeset.change(cs), :repo, Elixir.MyApp.Repo),
            :insert
          )

          Repo.insert_or_update!(cs)
          →
          Elixir.Kernel.then(
            Elixir.Map.replace!(Elixir.Ecto.Changeset.change(cs), :repo, Elixir.MyApp.Repo),
            fn changeset ->
              Elixir.Ecto.Changeset.apply_action!(
                changeset,
                Elixir.Kernel.if(Elixir.Ecto.get_meta(changeset.data, :state) == :loaded,
                  do: :update,
                  else: :insert
                )
              )
            end
          )

      The argument is normalised through `Ecto.Changeset.change/1`, which is **total over both
      shapes** Repo writes accept — a bare struct (`insert`/`delete`) *and* a changeset
      (`update`/`insert_or_update`) — so the rewrite never breaks on the struct case.
      `apply_action` faithfully preserves the `{:ok, struct}` / `{:error, changeset}` shape (and
      `apply_action!` raises `Ecto.InvalidChangesetError`, exactly like `insert!`), so the mutant
      diverges from the real write on **only** the success path: it skips persistence and the
      DB-enforced constraints (`unique_constraint`, `foreign_key_constraint`, …) that fire only on
      the real call. So it survives unless a test drives a *successful* write and asserts a
      persistence consequence (a row present, `id`/timestamps assigned, a constraint violated) —
      a precise, well-defined kill condition. Excludes `insert_all`/`update_all` (bulk, no
      changeset).

      **Error-path parity is what makes that kill condition precise**, so the rewrite reproduces
      the two pieces of metadata a real write stamps on the changeset it hands back
      (`Ecto.Repo.Schema`'s `put_repo_and_action/4`), which `apply_action/2` on its own does not:

        * the **Repo** — hence the `Map.replace!(…, :repo, …)` stage, carrying the configured
          `repo:`. (A plain call, not `%{… | repo: …}`, so the one stage composes into the nested
          and piped forms alike.)
        * the **action** — fixed per write for `insert`/`update`/`delete`, but *chosen at runtime*
          for `insert_or_update`, which Ecto routes to insert or update on the changeset data's
          `__meta__` state. The mutant reads that same state, so an invalid **loaded** changeset
          still comes back `action: :update` (and `insert_or_update!` still raises
          `Ecto.InvalidChangesetError` saying "could not perform **update**"). Hard-coding
          `:insert` there made the mutant differ from the baseline on the *invalid* path, killing
          it with tests that never exercise persistence at all — see NOTES "Persistence: the
          rewrite restates the write's Repo and action".

      With those restored, an invalid changeset yields the same `{:error, changeset}` in mutant
      and baseline. Two residual divergences are deliberate: `changeset.repo_opts` stays `[]` (the
      real value carries the write's options *and*, when the Repo enables `:stacktrace`, a live
      process stacktrace — unreproducible, and varying run to run), and Ecto's own argument
      guards are not restated (`insert_or_update` raises `ArgumentError` for a bare struct or a
      changeset in a state other than `:built`/`:loaded`, where the mutant returns a result).
      Both are programmer-error paths no persistence test asserts on.

    * **`:on_conflict`** — swap an explicit `on_conflict:` atom on an `insert`/`insert!`/`insert_all`
      (the writes that take the option) for the *distinct* alternative it conflicts-handles to:
      `:nothing`→`:raise` (silent-skip → crash — a survivor means no test exercises the upsert's
      conflict path), `:raise`→`:nothing` (crash → silent-skip — kill with a test asserting a
      duplicate fails), and `:replace_all`→`:nothing` (overwrite-row → keep-old-row — kill with a
      test that asserts the conflicting row was actually overwritten). Every *target* (`:raise`,
      `:nothing`) is valid with no `conflict_target` on all dialects, so each swap is crash-free.
      A swap **to `:raise` also drops any written `conflict_target:` pair** — Ecto forbids the
      combination (`ArgumentError`, ":conflict_target option is forbidden when :on_conflict is
      :raise", raised in the planner before any SQL), so keeping the pair would turn the mutant
      into an unconditional crasher (raising on *every* insert, conflict or not — a
      trivially-killed non-mutant) instead of the intended crash-on-conflict. A swap to
      `:nothing` keeps the pair: `:nothing` accepts a target, and the target still *arbitrates* —
      `ON CONFLICT (email) DO NOTHING` skips only conflicts on the named constraint while a
      conflict on any other unique constraint raises in mutant and baseline alike, so preserving
      the author's arbiter preserves the semantics. `:replace_all` is a swap **source** only,
      never a target — the reverse needs a `conflict_target` on Postgres, so a target-less swap
      would be a runtime crash (a trivially-killed non-mutant). Non-atom `on_conflict:` values (a
      `{:replace, …}` tuple, a keyword-list update, a query) are left untouched.

  **Pipe-aware.** The `:persistence` rewrite is one **stage chain** over the value the write would
  have persisted — `change()`, then the `:repo` stamp, then the `apply_action` call — rendered
  from a single table (`stages/3`) in whichever form the source wrote. Piped
  (`cs |> Repo.insert()`) the value is the `|>` left-hand side, so the chain ships as a
  right-nested pipe stage Mutare splices onto it — `cs |> (change() |> Map.replace!(…) |>
  apply_action(:insert))`, which flattens to the intended pipe. Unpiped the same stages nest as
  calls around the written argument, *not* as a pipe on it: `|>` binds tighter than most
  operators, so piping an argument that is itself an operator expression would re-associate it,
  where a nested call's parentheses cannot. The `:on_conflict` swap rebuilds the call in its
  written form via `Mutare.Calls`, so it is pipe-position-agnostic.
  """

  alias Mutare.Ecto.{AST, Config, Context, RepoCall, Tag}
  alias Mutare.Ecto.AST.KeywordList

  @behaviour Mutare.Ecto.SubMutator

  # Alias-proof `Elixir.Ecto.Changeset` reference — see `Mutare.Ecto.AST`.
  @changeset Mutare.AST.absolute_alias([:Ecto, :Changeset])

  # The variable the dynamic-action mutant binds its staged changeset to (`dynamic_apply/1`). A
  # plain source-AST var: it is read only inside the `fn` that introduces it, so shadowing an
  # outer binding of the same name is unobservable.
  @staged {:changeset, [], nil}

  # Each persisting write → the `apply_action` function (raising or not) and the action atom it
  # passes. The action mirrors the write, except for `insert_or_update`, which Ecto routes to an
  # insert or an update per call: `:dynamic` marks it as read from the changeset at runtime
  # (`dynamic_apply/1`) rather than fixed here.
  @writes %{
    insert: {:apply_action, :insert},
    update: {:apply_action, :update},
    delete: {:apply_action, :delete},
    insert_or_update: {:apply_action, :dynamic},
    insert!: {:apply_action!, :insert},
    update!: {:apply_action!, :update},
    delete!: {:apply_action!, :delete},
    insert_or_update!: {:apply_action!, :dynamic}
  }

  # Writes that accept an `on_conflict:` option: the single-row insert family and bulk `insert_all`.
  # (`insert_all` has no `!` twin; `update`/`delete` take no `on_conflict`.)
  @on_conflict_writes ~w(insert insert! insert_all)a

  # Each explicit `on_conflict:` atom → the *distinct* alternative it swaps to (the table, its
  # `:replace_all`-as-source-only asymmetry, and the `:raise`/`conflict_target` rule are explained
  # in the moduledoc). Non-atom values read as `nil` via `AST.atom_value` and are skipped.
  @on_conflict_swaps %{nothing: :raise, raise: :nothing, replace_all: :nothing}

  @doc "RepoWrite mutations for `node` as `:persistence`/`:on_conflict` tags, or `[]`."
  @spec mutations(Macro.t(), Context.t()) :: [Tag.t()]
  @impl Mutare.Ecto.SubMutator
  def mutations(node, %Context{config: config, pipe_mode: pipe_mode} = context) do
    case RepoCall.resolve(node, context) do
      {fun, args, rebuild} ->
        repo = Config.repo_key(config)

        # mutare:ignore[operand_swap] family order is irrelevant — mutations are consumed as a set
        persistence(fun, args, pipe_mode, repo) ++ on_conflict(fun, args, rebuild)

      nil ->
        []
    end
  end

  # `:persistence` — replace the write with the non-persisting `apply_action` chain.
  defp persistence(fun, args, pipe_mode, repo) do
    case @writes[fun] do
      nil -> []
      {action_fun, action} -> wrap(chain(stages(action_fun, action, repo), args, pipe_mode))
    end
  end

  defp wrap(nil), do: []
  defp wrap(node), do: [Tag.new(:persistence, node)]

  # The mutant as one chain over the value the write would have persisted:
  #
  #     value |> Ecto.Changeset.change() |> Map.replace!(:repo, Repo) |> <apply the action>
  #
  # Each stage builds itself from its *leading* arguments — `[]` as a pipe stage, `[value]` as a
  # nested call — so `chain/3` renders this one table into either written form and the piped and
  # unpiped mutants cannot drift apart. Why `change/1` normalises the value, why the `:repo` stamp
  # is here at all, and what stays unreproduced: the moduledoc.
  defp stages(action_fun, action, repo) do
    [
      fn lead -> changeset(:change, lead) end,
      fn lead -> repo_stamp(lead, repo) end,
      apply_stage(action_fun, action)
    ]
  end

  # `Map.replace!(value, :repo, Repo)` — the Repo a real write records on the changeset it returns.
  # `Map.replace!/3` rather than `%{value | repo: Repo}` because a plain call is what composes into
  # both written forms, and it raises loudly if `Ecto.Changeset` ever drops the field.
  defp repo_stamp(lead, repo) do
    Mutare.AST.absolute_call([:Map], :replace!, lead ++ [literal(:repo), repo_module(repo)])
  end

  # The closing stage. A write that names its action applies it directly; `insert_or_update` binds
  # the staged changeset through `Kernel.then/2` first, because its action is read off that
  # changeset and the written argument must not be evaluated a second time to get at it.
  defp apply_stage(action_fun, :dynamic) do
    fn lead -> Mutare.AST.absolute_call([:Kernel], :then, lead ++ [dynamic_apply(action_fun)]) end
  end

  defp apply_stage(action_fun, action) do
    fn lead -> changeset(action_fun, lead ++ [literal(action)]) end
  end

  # Piped: the value is the pipe's LHS (not in `args`), so fold the stages into a right-nested pipe
  # that Mutare splices onto it. Unpiped: fold them into calls nested around the written argument
  # (never a pipe on it — see the moduledoc). Either way the write's opts are dropped; a
  # non-persisting stub takes none.
  defp chain([head | rest], _args, :piped),
    do: Enum.reduce(rest, head.([]), fn stage, acc -> {:|>, [], [acc, stage.([])]} end)

  defp chain(stages, [arg | _opts], :unpiped),
    do: Enum.reduce(stages, arg, fn stage, acc -> stage.([acc]) end)

  # A write with no visible argument has no value to restate: no mutant, rather than a broken one.
  defp chain(_stages, [], :unpiped), do: nil

  # `fn changeset -> apply_action(changeset, <the action Ecto would have chosen>) end`. Ecto routes
  # `insert_or_update` on the changeset data's `__meta__` state — `:loaded` is an existing row (an
  # update), anything else a new one (an insert) — so the mutant reads the same state through
  # `Ecto.get_meta/2` and stamps the same `changeset.action` on the error path.
  defp dynamic_apply(action_fun) do
    {:fn, [], [{:->, [], [[@staged], changeset(action_fun, [@staged, dynamic_action()])]}]}
  end

  # The action itself: `:update` for a changeset over a row already loaded from the DB, `:insert`
  # otherwise — Ecto's own `insert_or_update` dispatch. Written `Kernel.if/2` in full because `if`
  # is an ordinary `Kernel` macro a target app is free to exclude from its imports.
  defp dynamic_action do
    state = Mutare.AST.absolute_call([:Ecto], :get_meta, [data(@staged), literal(:state)])

    Mutare.AST.absolute_call([:Kernel], :if, [
      {:==, [], [state, literal(:loaded)]},
      [
        {Mutare.AST.keyword_key(:do), literal(:update)},
        {Mutare.AST.keyword_key(:else), literal(:insert)}
      ]
    ])
  end

  # `changeset.data` — the schema struct Ecto reads the persistence state off.
  defp data(node), do: {{:., [], [node, :data]}, [no_parens: true], []}

  # The configured `repo:` as an alias-proof module reference — the module a real write records on
  # the changeset. `Config.repo_key/1` returns `Mutare.Calls.module_key/1`'s encoding: a segment
  # path for an Elixir module, a bare atom for an Erlang one.
  defp repo_module(path) when is_list(path), do: Mutare.AST.absolute_alias(path)
  defp repo_module(erlang) when is_atom(erlang), do: literal(erlang)

  defp changeset(fun, args), do: Mutare.AST.remote_call(@changeset, fun, args)

  defp literal(value), do: Mutare.AST.literal(value)

  # `:on_conflict` — flip `on_conflict: :nothing` → `:raise` in the trailing keyword-list arg,
  # rebuilding the call in its written form. Pipe-agnostic: the opts list is the last visible arg
  # in both forms, and a non-literal/absent `on_conflict` value yields nothing.
  defp on_conflict(fun, args, rebuild) when fun in @on_conflict_writes and args != [] do
    {init, [last]} = Enum.split(args, -1)

    case swap_on_conflict(last) do
      nil -> []
      swapped -> [Tag.new(:on_conflict, rebuild.(fun, init ++ [swapped]))]
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
            options
            |> KeywordList.put_value(index, Mutare.AST.literal(to))
            |> drop_forbidden_target(to)
            |> KeywordList.to_ast()
          else
            _ -> nil
          end
        end)

      nil ->
        nil
    end
  end

  defp swap_on_conflict(_other), do: nil

  # `:raise` forbids a `conflict_target:` (see the moduledoc), so the swap to it drops the pair
  # whatever its value shape; `:nothing` keeps the author's arbiter.
  defp drop_forbidden_target(options, :raise),
    do: KeywordList.reject_key(options, :conflict_target)

  defp drop_forbidden_target(options, _to), do: options
end
