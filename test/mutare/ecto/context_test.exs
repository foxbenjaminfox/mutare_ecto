defmodule Mutare.Ecto.ContextTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.{Config, Context}

  # `Context.new/1` is the plugin's one reader of core's callback context: the Dispatcher
  # (`mutate/2`), the host (`host/2`), and `Mutare.Ecto.finalize/2` each unpack through it once,
  # and everything inside consumes the struct. Its strictness is therefore the plugin's whole
  # contract with core's context — a missing or raw `:config` is a programming error, `pipe_mode`
  # is required, and an absent `:mutators` is core's ordinary-node offer, read as `[]`.
  describe "new/1" do
    test "raises when the context lacks the init/1-parsed :config, or carries raw options there" do
      # Never an implicit all-families/no-repo config.
      assert_raise ArgumentError,
                   ~r/expected core's callback context .* got: %\{pipe_mode: :unpiped\}\z/,
                   fn -> Context.new(%{pipe_mode: :unpiped}) end

      assert_raise ArgumentError,
                   ~r/got: %\{config: \[families: \[:comparison\]\], pipe_mode: :unpiped\}\z/,
                   fn ->
                     Context.new(%{config: [families: [:comparison]], pipe_mode: :unpiped})
                   end
    end

    test "raises when the context lacks core's :pipe_mode" do
      # The base context's one guaranteed key; a producer's `%Context{pipe_mode: …}` match relies
      # on it, so the constructor refuses rather than storing nil.
      assert_raise ArgumentError, ~r/expected core's callback context/, fn ->
        Context.new(%{config: Config.parse!([])})
      end
    end

    test "unpacks config and pipe_mode; an absent :mutators (an ordinary node offer) reads as []" do
      config = Config.parse!(families: [:bound])

      assert %Context{config: ^config, pipe_mode: :piped, mutators: []} =
               Context.new(%{config: config, pipe_mode: :piped})
    end

    test "carries the run's specs through when core injects :mutators (the sub-contract seams)" do
      config = Config.parse!([])
      specs = [Mutare.Mutator.Spec.coerce(Mutare.Mutators.Arithmetic)]

      assert %Context{mutators: ^specs} =
               Context.new(%{config: config, pipe_mode: :unpiped, mutators: specs})
    end

    test "ignores the rest of core's context (:name, :opts, :behaviours, :marks)" do
      # The plugin models exactly the three facts it reads; core's other keys ride along unread.
      config = Config.parse!([])

      core_context = %{
        config: config,
        pipe_mode: :unpiped,
        name: :ecto,
        opts: [],
        behaviours: MapSet.new(),
        marks: MapSet.new()
      }

      assert Context.new(core_context) == %Context{config: config, pipe_mode: :unpiped}
    end
  end
end
