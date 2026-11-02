defmodule GoodFlows.Pools.ProvisionMemberJob do
  @moduledoc """
  PgFlow job: Provisions one pool member (setup, helper, golden checkpoint) (`%{"member_id" => id}`).

  `max_attempts: 1`: the work is fenced on the member's state and owner,
  and `GoodFlows.Pools.Reconciler` re-enqueues a member left without a job.
  The hard timeout (`GoodFlows.Pools.Config.provision_job_timeout_seconds/0`) is checked
  against its budget at startup. See `GoodFlows.Pools.Provisioner`.
  """
  use PgFlow.Job

  alias GoodFlows.Pools.Provisioner

  @job queue: :pool_member_provision,
       max_attempts: 1,
       timeout: GoodFlows.Pools.Config.provision_job_timeout_seconds()

  perform :provision do
    fn input, _ctx -> Provisioner.provision(Map.fetch!(input, "member_id")) end
  end
end
