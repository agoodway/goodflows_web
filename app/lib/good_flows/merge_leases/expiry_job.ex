defmodule GoodFlows.MergeLeases.ExpiryJob do
  @moduledoc """
  PgFlow job that marks every active merge lease past its `expires_at` as
  `expired` (`GoodFlows.MergeLeases.expire_due/1`). Enqueued every 30
  seconds by `GoodFlows.MergeLeases.ExpiryScheduler`. Each lease expires
  at most once, so an overlapping or retried run is harmless.
  """
  use PgFlow.Job

  alias GoodFlows.MergeLeases

  @job queue: :merge_lease_expiry, max_attempts: 3, timeout: 120

  perform :expire do
    fn _input, _ctx -> %{"expired" => MergeLeases.expire_due()} end
  end
end
