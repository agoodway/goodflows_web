defmodule GoodFlows.ChangeRequests.RecomputeJob do
  @moduledoc """
  PgFlow job that recomputes every `draft` and `open` change request of a
  project (`%{"project_id" => id}`) after a policy write with more of them
  than the inline limit. Recomputing is idempotent, so it may retry.
  """
  use PgFlow.Job

  alias GoodFlows.ChangeRequests

  @job queue: :change_request_recompute, max_attempts: 3, timeout: 600

  perform :recompute do
    fn input, _ctx ->
      %{"recomputed" => ChangeRequests.recompute_project(Map.fetch!(input, "project_id"))}
    end
  end
end
