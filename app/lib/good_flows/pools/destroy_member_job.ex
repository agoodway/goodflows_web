defmodule GoodFlows.Pools.DestroyMemberJob do
  @moduledoc """
  PgFlow job: Destroys one pool member's sprite and removes its row (`%{"member_id" => id}`).

  `max_attempts: 1`: the work is fenced on the member's state and owner,
  and `GoodFlows.Pools.Reconciler` re-enqueues a member left without a job.
  The hard timeout (`GoodFlows.Pools.Config.member_job_timeout_seconds/0`) is checked
  against its budget at startup. See `GoodFlows.Pools.Provisioner`.
  """
  use PgFlow.Job

  alias GoodFlows.Pools.Provisioner

  @job queue: :pool_member_destroy,
       max_attempts: 1,
       timeout: GoodFlows.Pools.Config.member_job_timeout_seconds()

  perform :destroy do
    fn input, _ctx -> Provisioner.destroy(Map.fetch!(input, "member_id")) end
  end
end
