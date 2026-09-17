defmodule Mutare.Ecto.SelectorSyncTest do
  use ExUnit.Case, async: true

  # The home of a suite rule: **a test module that can run a metamutant is `async: false`.**
  #
  # Which mutant a compiled metamutant runs is one global `:persistent_term` slot
  # (`Mutare.Selector`), and core's flip helpers are an unguarded read-put-run-restore over it
  # (`Mutare.Test.with_active_mutant/2`, which documents the `async: false` requirement). ExUnit
  # runs `async: true` modules concurrently, so from one:
  #
  #   * a flip is visible to every other module — another test's pinned baseline, or its own
  #     mutant, is replaced mid-observation;
  #   * an *unpinned* run of a metamutant (`woven.q()`) takes whatever id a concurrent flipper
  #     holds active, so a "baseline" assertion compares against some mutant;
  #   * two interleaved flips restore out of order — A saves 0, B saves A's id, A restores 0, B
  #     restores A's id — and the slot stays at a mutant for the rest of the run, sync modules
  #     included.
  #
  # Each window is microseconds wide, so the failure is a rare flake with no trail back to its
  # cause; hence a structural check instead of a convention. It reads each test file's AST and
  # rejects an `async: true` module that names any way of obtaining or steering a runnable
  # metamutant. Such tests live in an `async: false` sibling module in the same file
  # (`HostTest.Runtime`, …), and pin the baseline they read (`with_active_mutant(0, …)`) rather
  # than trust the ambient selection.

  # Every way this suite gets a runnable instrumented module, or moves the selector.
  # `assert_compiles`/`metamutant` are absent on purpose: they compile or render, and hand back
  # nothing to run.
  @gateway_calls [:compile_metamutant, :with_active_mutant, :observe_mutant, :assert_builds]
  @gateway_modules [[:Mutare, :Selector], [:Mutare, :Ecto, :SemanticHarness]]

  test "no async test module can run a metamutant or move the selector" do
    offenders =
      for file <- Path.wildcard(Path.join(__DIR__, "**/*_test.exs")),
          {module, :async, body} <- test_modules(file),
          gateway <- gateways(body) do
        "#{Path.relative_to_cwd(file)}: #{module} is async: true but uses #{gateway}"
      end

    assert offenders == [],
           "move these tests to an `async: false` sibling module (the selector is global):\n  " <>
             Enum.join(Enum.uniq(offenders), "\n  ")
  end

  test "the check sees a gateway in an async module, and only there" do
    # The guard guarding itself: a scan that silently matched nothing would pass forever.
    source = """
    defmodule A do
      use ExUnit.Case, async: true
      test "flips", do: Mutare.Test.observe_mutant([], {"a", "b"}, fn -> :ok end)

      defmodule Nested do
        use ExUnit.Case, async: false
        test "may", do: Mutare.Test.with_active_mutant(0, fn -> :ok end)
      end
    end

    defmodule B do
      use ExUnit.Case
      alias Mutare.Ecto.SemanticHarness, as: H
      test "sync by default", do: H.compile("")
    end

    defmodule C do
      use ExUnit.Case, async: true
      # observe_mutant in a comment, and "compile_metamutant" in a string, are not calls.
      test "renders only", do: "compile_metamutant"
    end
    """

    modules = source |> Code.string_to_quoted!() |> test_modules_in()

    assert [{"A", :async, a}, {"A.Nested", :sync, _}, {"B", :sync, _}, {"C", :async, c}] =
             Enum.sort(modules)

    assert gateways(a) == ["observe_mutant"]
    assert gateways(c) == []
  end

  defp test_modules(file),
    do: file |> File.read!() |> Code.string_to_quoted!() |> test_modules_in()

  # Every `defmodule` that `use`s `ExUnit.Case`, as `{name, :async | :sync, own_body}` — its body
  # with nested modules cut out, since each of those answers for itself.
  defp test_modules_in(ast, prefix \\ []) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _, name}, [do: body]]}, acc ->
          path = prefix ++ name
          nested = test_modules_in(body, path)
          own = without_nested_modules(body)

          this =
            case async_flag(own) do
              nil -> []
              flag -> [{Enum.map_join(path, ".", &Atom.to_string/1), flag, own}]
            end

          # Replace the node so the walk does not descend and report the nested modules twice.
          {nil, this ++ nested ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp without_nested_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  # `:async`/`:sync` for a module that `use`s `ExUnit.Case` (sync being ExUnit's default), `nil`
  # for one that does not.
  defp async_flag(body) do
    {_body, flag} =
      Macro.prewalk(body, nil, fn
        {:use, _meta, [{:__aliases__, _, [:ExUnit, :Case]} | opts]} = node, _acc ->
          async? = opts |> List.first([]) |> Keyword.get(:async, false)
          {node, if(async?, do: :async, else: :sync)}

        node, acc ->
          {node, acc}
      end)

    flag
  end

  defp gateways(body) do
    {_body, found} =
      Macro.prewalk(body, [], fn
        {{:., _, [_module, name]}, _meta, _args} = node, acc when name in @gateway_calls ->
          {node, [Atom.to_string(name) | acc]}

        {name, _meta, args} = node, acc when name in @gateway_calls and is_list(args) ->
          {node, [Atom.to_string(name) | acc]}

        {:__aliases__, _meta, name} = node, acc when name in @gateway_modules ->
          {node, [Enum.map_join(name, ".", &Atom.to_string/1) | acc]}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.uniq() |> Enum.sort()
  end
end
