defmodule GoodFlows.ChangeRequests.RecomputeJob do
  @moduledoc """
  PgFlow job that recomputes `draft` and `open` change requests of a
  project. With `%{"project_id" => id}` it recomputes all of them, after a
  policy write with more of them than the inline limit. With a
  `"change_id"` too it recomputes only those that depend on that change
  id, after a change request linking it changes state. Recomputing is
  idempotent, so it may retry.
  """
  use PgFlow.Job

  alias GoodFlows.ChangeRequests

  @job queue: :change_request_recompute, max_attempts: 3, timeout: 600

  perform :recompute do
    fn input, _ctx ->
      project_id = Map.fetch!(input, "project_id")

      recomputed =
        case input do
          %{"change_id" => change_id} ->
            ChangeRequests.recompute_dependents(project_id, change_id)

          _project ->
            ChangeRequests.recompute_project(project_id)
        end

      %{"recomputed" => recomputed}
    end
  end
end
