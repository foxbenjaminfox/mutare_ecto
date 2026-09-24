defmodule Mutare.Ecto.ContextTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Config, Context}

  # `Context.new/1` is the plugin's one reader of core's callback context: the Dispatcher
  # (`mutate/2`), the host (`host/2`), and `Mutare.Ecto.finalize/2` each unpack through it once,
  # and everything inside consumes the struct. Its strictness is therefore the plugin's whole
  # contract with core's context — a missing or raw `:config` is a programming error, and an
  # absent `:mutators` is core's ordinary-node offer, read as `[]`.
  describe "new/1" do
    test "raises when the context lacks the init/1-parsed :config, or carries raw options there" do
      # Never an implicit all-families/no-repo config.
      assert_raise ArgumentError,
                   ~r/expected core's callback context .* got: %\{\}\z/,
                   fn -> Context.new(%{}) end

      assert_raise ArgumentError,
                   ~r/got: %\{config: \[families: \[:comparison\]\]\}\z/,
                   fn -> Context.new(%{config: [families: [:comparison]]}) end
    end

    test "unpacks config; an absent :mutators (an ordinary node offer) reads as []" do
      config = Config.parse!(families: [:bound])

      assert %Context{config: ^config, mutators: []} = Context.new(%{config: config})
    end

    test "carries the run's specs through when core injects :mutators (the sub-contract seams)" do
      config = Config.parse!([])
      specs = [Mutare.Mutator.Spec.coerce(Mutare.Mutators.Arithmetic)]

      assert %Context{mutators: ^specs} = Context.new(%{config: config, mutators: specs})
    end

    test "keeps core's map whole for the seams, and models nothing else of it" do
      # The plugin reads exactly the two facts above; core's other keys (`:name`, `:opts`,
      # `:behaviours`, `:marks`, `:resolution`) ride along in `core`, unread, for the island
      # sub-contract and the plugin's own resolution of written regions.
      config = Config.parse!([])

      core_context = %{
        config: config,
        name: :ecto,
        opts: [],
        behaviours: MapSet.new(),
        marks: MapSet.new(),
        resolution: :opaque
      }

      assert Context.new(core_context) == %Context{config: config, core: core_context}
    end
  end
end
