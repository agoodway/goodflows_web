defmodule GoodFlows.Spry.RunJob do
  @moduledoc """
  PgFlow job that executes one admitted run (`%{"run_id" => id}`).

  `max_attempts: 1` because steps are not assumed idempotent. The hard
  timeout (`GoodFlows.Spry.Config.job_timeout_seconds/0`) covers the total
  run budget plus finalization overhead. See `GoodFlows.Spry.Runner`.
  """
  use PgFlow.Job

  alias GoodFlows.Spry.Runner

  @job queue: :spry_run,
       max_attempts: 1,
       timeout: GoodFlows.Spry.Config.job_timeout_seconds()

  perform :execute do
    fn input, ctx ->
      Runner.execute(Map.fetch!(input, "run_id"), ctx.run_id)
    end
  end
end
