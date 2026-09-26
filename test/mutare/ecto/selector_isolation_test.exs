defmodule Mutare.Ecto.SelectorIsolationTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.TestSupport
  alias Mutare.{Selector, Test}

  # Core isolates its helpers per test-module execution, including across setup_all and test
  # processes. Our direct-transform wrapper must join that same isolation before transforming.
  setup_all do
    source = """
    defmodule Q do
      import Ecto.Query
      def query, do: from(p in "posts", where: p.views > 5)
    end
    """

    opts = [families: [:comparison]]
    {[module], sites} = Test.compile_metamutant(source, TestSupport.mutators(opts))

    %{source: source, opts: opts, fixture: module, sites: sites, selector_key: Selector.key()}
  end

  test "sites establishes the module's selector even as the test's first helper", context do
    assert Process.get(Selector.process_key()) == nil
    assert [_ | _] = TestSupport.sites(context.source, context.opts)
    assert Process.get(Selector.process_key()) == context.selector_key
    refute context.selector_key == Selector.default_key()
  end

  test "a fixture compiled in setup_all responds to selection in the test", context do
    {baseline, mutated} =
      Test.observe_mutant(context.sites, {"p.views > 5", "p.views >= 5"}, fn ->
        inspect(context.fixture.query())
      end)

    assert baseline =~ "p0.views > 5"
    assert mutated =~ "p0.views >= 5"
    assert Test.with_active_mutant(0, fn -> inspect(context.fixture.query()) end) == baseline
    assert Selector.key() == context.selector_key
  end
end
