defmodule GoodFlows.Caches.SweepJob do
  @moduledoc """
  PgFlow job that runs one `GoodFlows.VerifyRuns.Sweep` (whose deleted
  artifacts queue objects) and then one `GoodFlows.Caches.Sweep`. Enqueued
  every 5 minutes by `GoodFlows.Caches.SweepScheduler`.

  The cache sweep runs even when the verify run sweep raises; the job then
  re-raises that error, so the failure is still reported.
  """
  use PgFlow.Job

  alias GoodFlows.Caches.Sweep
  alias GoodFlows.VerifyRuns.Sweep, as: VerifyRunSweep

  @job queue: :cache_sweep, max_attempts: 1, timeout: 300

  perform :sweep do
    fn _input, _ctx ->
      verify_runs =
        try do
          {:ok, VerifyRunSweep.run()}
        rescue
          error -> {:error, error, __STACKTRACE__}
        end

      caches = Sweep.run()

      case verify_runs do
        {:ok, counts} ->
          Map.new(Map.merge(counts, caches), fn {key, value} -> {Atom.to_string(key), value} end)

        {:error, error, stacktrace} ->
          reraise error, stacktrace
      end
    end
  end
end
