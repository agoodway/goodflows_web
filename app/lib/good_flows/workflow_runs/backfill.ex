defmodule GoodFlows.WorkflowRuns.Backfill do
  @moduledoc """
  Fills `failed_jobs` and `parent_run_id` from `payload` for rows stored
  by code that did not copy them. The migration
  `BackfillFailedJobsAndParentRunId` runs it, and
  `GoodFlows.Release.backfill_workflow_runs/0` runs it again once the new
  code is serving, for the rows the old code stored behind the migration's
  cursor.

  Only a failed run has a `failed` or `timed_out` result (the validator
  requires it), so `failed_jobs` is computed for rows with
  `outcome = 'failed'`. `parent_run_id` is copied for rows whose payload
  has the key. Rows are selected by `outcome` and `payload`, not by an
  empty column.

  The update runs in batches of 1,000 rows by `id`, one transaction per
  batch, so uploads continue meanwhile. Runs are immutable and each value
  is derived from `payload` alone, so rerunning it gives the same result.
  """

  @batch_size 1_000

  @next_batch """
  SELECT id FROM workflow_runs
  WHERE id > $1 AND (outcome = 'failed' OR payload ? 'parent_run_id')
  ORDER BY id
  LIMIT $2
  """

  @update """
  UPDATE workflow_runs SET
    failed_jobs = CASE WHEN outcome = 'failed' THEN ARRAY(
      SELECT r->>'name'
      FROM jsonb_array_elements(payload->'results') WITH ORDINALITY AS t(r, i)
      WHERE r->>'status' IN ('failed', 'timed_out')
      ORDER BY i
    ) ELSE failed_jobs END,
    parent_run_id = CASE WHEN payload ? 'parent_run_id'
      THEN (payload->>'parent_run_id')::uuid ELSE parent_run_id END
  WHERE id = ANY($1)
  """

  @doc "Runs the backfill on `repo`, one transaction per batch. Safe to rerun."
  @spec run(Ecto.Repo.t()) :: :ok
  def run(repo), do: backfill(repo, Ecto.UUID.dump!("00000000-0000-0000-0000-000000000000"))

  defp backfill(repo, after_id) do
    %{rows: rows} = repo.query!(@next_batch, [after_id, @batch_size], log: false)

    case rows do
      [] ->
        :ok

      rows ->
        ids = Enum.map(rows, fn [id] -> id end)
        {:ok, _result} = repo.transaction(fn -> repo.query!(@update, [ids], log: false) end)
        backfill(repo, List.last(ids))
    end
  end
end
