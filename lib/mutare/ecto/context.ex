defmodule Mutare.Ecto.Context do
  @moduledoc false
  # The plugin's own view of core's callback context (`t:Mutare.Mutator.context/0`) — the three
  # facts the plugin reads from it, unpacked **once** at each core → plugin boundary and threaded,
  # as this struct, to everything inside:
  #
  #   * `config` — the `init/1`-parsed `%Mutare.Ecto.Config{}` (`families:`/`dialects:`/`repo:`)
  #     core delivers as `context.config` on every per-spec path. Required: a miss, or raw options
  #     in its place, is a programming error, so `new/1` fails loudly rather than defaulting to an
  #     all-families, no-repo config.
  #   * `pipe_mode` — core's `:piped`/`:unpiped`, the base context's one guaranteed key. The
  #     pipe-aware producers read their effective argument positions off it.
  #   * `mutators` — the run's enabled `Mutare.Mutator.Spec`s, which core injects on the two
  #     sub-contract seams (a `host/2` offer, and the whole-call `mutate/2` offer of a registered
  #     macro) and omits on an ordinary node offer, where it descends the node itself. `[]` for the
  #     latter is the contract's reading of absence, not a fallback: the island sub-contract
  #     (`Mutare.Ecto.Island.subcontracted/3`) then relays nothing, correctly — there is no
  #     island core hasn't already reached.
  #
  # The boundaries are `Mutare.Ecto.Dispatcher.mutations/2` (the `mutate/2` path),
  # `Mutare.Ecto.Host.host/2` (the selector-host path), and `Mutare.Ecto.finalize/2` (the funnel
  # core runs on both) — each calls `new/1` exactly once, and no module inside reads core's map.
  # A producer pattern-matches the struct (`%Context{pipe_mode: pipe_mode}`), which is total —
  # every key exists on a struct — so no sub-mutator needs a defensive catch-all against a
  # context *shape*: core's optional keys are resolved here, before any producer runs. Every
  # other key core carries (`:opts`, `:behaviours`, `:marks`, …) is deliberately not modelled;
  # the plugin reads none of them.

  alias Mutare.Ecto.Config

  @enforce_keys [:config, :pipe_mode]
  defstruct [:config, :pipe_mode, mutators: []]

  @type t :: %__MODULE__{
          config: Config.t(),
          pipe_mode: Mutare.Mutator.pipe_mode(),
          mutators: [Mutare.Mutator.Spec.t()]
        }

  @doc """
  Unpack core's callback context into the plugin's `%Context{}` — the one reader of core's map.
  Raises when the context lacks the `init/1`-parsed `:config` (or carries raw options there) or
  core's `:pipe_mode`; an absent `:mutators` reads as `[]` (an ordinary node offer).
  """
  @spec new(Mutare.Mutator.context()) :: t()
  def new(%{config: %Config{} = config, pipe_mode: pipe_mode} = context)
      when pipe_mode in [:piped, :unpiped] do
    %__MODULE__{config: config, pipe_mode: pipe_mode, mutators: Map.get(context, :mutators, [])}
  end

  def new(other) do
    raise ArgumentError,
          "Mutare.Ecto.Context.new/1 expected core's callback context with the init/1-parsed " <>
            ":config and a :pipe_mode, got: #{inspect(other)}"
  end
end
