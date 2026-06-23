defmodule :mutare_cov do
  @moduledoc false
  # A stub of the coverage helper Mutare's Sandbox normally writes into a real run. A
  # metamutant rendered by `Mutare.transform_string/2` references `:mutare_cov.hit/1` in every
  # selector catch-all, so this stub lets the compile-safety tests compile a rendered metamutant
  # in a plain test process. The real implementation lives in `Mutare.Coverage.Recorder`.
  def hit(_ids), do: :ok
end
