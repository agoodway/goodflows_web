defmodule GoodFlows.Caches.SweepJob do
  @moduledoc """
  PgFlow job that runs one `GoodFlows.Caches.Sweep`. Enqueued every
  5 minutes by `GoodFlows.Caches.SweepScheduler`.
  """
  use PgFlow.Job

  alias GoodFlows.Caches.Sweep

  @job queue: :cache_sweep, max_attempts: 1, timeout: 300

  perform :sweep do
    fn _input, _ctx ->
      Map.new(Sweep.run(), fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end
end
