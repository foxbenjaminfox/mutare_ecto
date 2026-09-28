defmodule Mutare.Ecto.Context do
  @moduledoc false
  # The plugin's own view of core's callback context (`t:Mutare.Mutator.context/0`) — the two
  # facts the plugin reads from it, unpacked **once** at each core → plugin boundary and threaded,
  # as this struct, to everything inside:
  #
  #   * `config` — the `init/1`-parsed `%Mutare.Ecto.Config{}` (`families:`/`dialects:`/`repo:`)
  #     core delivers as `context.config` on every per-spec path. Required: a miss, or raw options
  #     in its place, is a programming error, so `new/1` fails loudly rather than defaulting to an
  #     all-families, no-repo config.
  #   * `mutators` — the run's enabled `Mutare.Mutator.Spec`s, which core injects on the two
  #     sub-contract seams (a `host/2` offer, and the whole-call `mutate/2` offer of a registered
  #     macro) and omits on an ordinary node offer, where it descends the node itself. `[]` for the
  #     latter is the contract's reading of absence, not a fallback: the island sub-contract
  #     (`Mutare.Ecto.Island.subcontracted/4`) then relays nothing, correctly — there is no
  #     island core hasn't already reached.
  #   * `core` — core's map itself, kept for the two places the plugin hands code back to core:
  #     the island sub-contract (`Mutare.Analyze.collect_expression/3` wants the callback
  #     context unchanged — it carries the enclosing call's lexical environment, in which core
  #     resolves the island) and the plugin's own resolution of the regions core left as written
  #     (`Mutare.Ecto.Resolved`). The plugin reads nothing else off it.
  #
  # Nothing here says how a call was written: core offers a pipe stage as the direct call it is
  # sugar for, so a producer reads argument positions off the call alone.
  #
  # The boundaries are `Mutare.Ecto.Dispatcher.mutations/2` (the `mutate/2` path),
  # `Mutare.Ecto.Host.host/2` (the selector-host path), and `Mutare.Ecto.finalize/2` (the funnel
  # core runs on both) — each calls `new/1` exactly once, and no module inside reads core's map.
  # A producer pattern-matches the struct (`%Context{config: config}`), which is total —
  # every key exists on a struct — so no sub-mutator needs a defensive catch-all against a
  # context *shape*: core's optional keys are resolved here, before any producer runs. Every
  # other key core carries (`:opts`, `:behaviours`, `:marks`, `:resolution`, …) is deliberately
  # not modelled; the plugin reads none of them.

  alias Mutare.Ecto.Config

  @enforce_keys [:config, :core]
  defstruct [:config, :core, mutators: []]

  @type t :: %__MODULE__{
          config: Config.t(),
          core: Mutare.Mutator.context(),
          mutators: [Mutare.Mutator.Spec.t()]
        }

  @doc """
  Unpack core's callback context into the plugin's `%Context{}` — the one reader of core's map.
  Raises when the context lacks the `init/1`-parsed `:config` (or carries raw options there);
  an absent `:mutators` reads as `[]` (an ordinary node offer).
  """
  @spec new(Mutare.Mutator.context()) :: t()
  def new(%{config: %Config{} = config} = context) do
    %__MODULE__{config: config, core: context, mutators: Map.get(context, :mutators, [])}
  end

  def new(other) do
    raise ArgumentError,
          "Mutare.Ecto.Context.new/1 expected core's callback context with the init/1-parsed " <>
            ":config, got: #{inspect(other)}"
  end
end
