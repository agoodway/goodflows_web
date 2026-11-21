defmodule GoodFlows.Caches.SweepJob do
  @moduledoc """
  PgFlow job that runs one `GoodFlows.VerifyRuns.Sweep` (whose deleted
  artifacts queue objects), the 90-day project event retention sweep
  (`GoodFlows.ProjectEvents.sweep/1`) and then one `GoodFlows.Caches.Sweep`. Enqueued
  every 5 minutes by `GoodFlows.Caches.SweepScheduler`.

  The cache sweep runs even when an earlier sweep raises; the job then
  re-raises that error, so the failure is still reported.
  """
  use PgFlow.Job

  alias GoodFlows.Caches.Sweep
  alias GoodFlows.ProjectEvents
  alias GoodFlows.VerifyRuns.Sweep, as: VerifyRunSweep

  @job queue: :cache_sweep, max_attempts: 1, timeout: 300

  perform :sweep do
    fn _input, _ctx ->
      verify_runs = attempt(&VerifyRunSweep.run/0)
      events = attempt(fn -> %{project_events_deleted: ProjectEvents.sweep()} end)
      caches = Sweep.run()

      case {verify_runs, events} do
        {{:ok, runs}, {:ok, deleted}} ->
          runs
          |> Map.merge(deleted)
          |> Map.merge(caches)
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

        {{:error, error, stacktrace}, _events} ->
          reraise error, stacktrace

        {_runs, {:error, error, stacktrace}} ->
          reraise error, stacktrace
      end
    end
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error, __STACKTRACE__}
  end
end
