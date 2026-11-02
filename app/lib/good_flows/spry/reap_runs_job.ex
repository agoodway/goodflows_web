defmodule GoodFlows.Spry.ReapRunsJob do
  @moduledoc """
  PgFlow job that runs one `GoodFlows.Spry.Reaper` sweep. Enqueued every
  5 minutes by `GoodFlows.Spry.ReaperScheduler`.
  """
  use PgFlow.Job

  alias GoodFlows.Spry.Reaper

  @job queue: :spry_reap_runs, max_attempts: 1, timeout: 300

  perform :reap do
    fn _input, _ctx ->
      summary = Reaper.reap()
      Map.new(summary, fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end
end
