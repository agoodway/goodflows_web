defmodule GoodFlows.VerifyRuns.Sweep do
  @moduledoc """
  One verify run sweep, run by `GoodFlows.Caches.SweepJob` with the cache
  sweep (design D6, D9):

  1. deletes `uploading` runs whose `expires_at` is past; deleting their
     artifact rows queues the objects in `cache_object_deletions`
     (database trigger), which `GoodFlows.Caches.Sweep` deletes from the
     bucket, and frees the `run_id`,
  2. deletes the objects of unexpired artifacts of `final` runs whose
     retention has ended and marks the rows `expired`: 30 days after every
     change request that counted the run is `merged` or `closed` (from
     `merged_at`, or the latest close), or 14 days after `finalized_at`
     when no change request counted it. A failed delete leaves the row
     unexpired, so a later sweep retries it. Run documents are kept.

  Step 2 is skipped without a bucket. Sweeps are idempotent.
  """
  import Ecto.Query

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.Repo
  alias GoodFlows.VerifyRuns.{Artifact, Run}

  @batch_size 1_000
  @counted_retention_days 30
  @uncounted_retention_days 14

  @typedoc "Counts of one sweep."
  @type summary :: %{
          verify_runs_expired: non_neg_integer(),
          artifacts_expired: non_neg_integer(),
          artifacts_failed: non_neg_integer()
        }

  @doc "Runs one sweep. Option: `:batch_size` (default 1,000)."
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    now = DateTime.utc_now()

    {expired_artifacts, failed} =
      if ObjectStore.configured?(), do: expire_artifacts(now, batch_size), else: {0, 0}

    %{
      verify_runs_expired: delete_uploading(now, batch_size, 0),
      artifacts_expired: expired_artifacts,
      artifacts_failed: failed
    }
  end

  defp delete_uploading(now, batch_size, total) do
    ids =
      from r in Run,
        where: r.status == "uploading" and r.expires_at < ^now,
        select: r.id,
        limit: ^batch_size

    {count, _rows} = delete_expired_uploading(ids, now)

    if count == batch_size,
      do: delete_uploading(now, batch_size, total + count),
      else: total + count
  end

  @doc false
  # Rechecks the state in the outer DELETE: under READ COMMITTED a run that
  # `commit` finalized after the subquery's snapshot is rechecked only
  # against this WHERE clause once its row lock is released.
  def delete_expired_uploading(ids, now) do
    Repo.delete_all(
      from r in Run,
        where: r.id in subquery(ids) and r.status == "uploading" and r.expires_at < ^now
    )
  end

  defp expire_artifacts(now, batch_size) do
    counted_cutoff = DateTime.add(now, -@counted_retention_days, :day)
    uncounted_cutoff = DateTime.add(now, -@uncounted_retention_days, :day)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.id, a.object_key
        FROM verify_run_artifacts a
        JOIN verify_runs r ON r.id = a.verify_run_id
        WHERE NOT a.expired AND r.status = 'final' AND (
          (EXISTS (SELECT 1 FROM verify_run_counts c WHERE c.verify_run_id = r.id)
           AND NOT EXISTS (
             SELECT 1 FROM verify_run_counts c
             JOIN change_requests cr ON cr.id = c.change_request_id
             WHERE c.verify_run_id = r.id AND (
               cr.state NOT IN ('merged', 'closed')
               OR (cr.state = 'merged' AND cr.merged_at > $1)
               OR (cr.state = 'closed' AND COALESCE(
                     (SELECT max(e.inserted_at) FROM change_request_events e
                      WHERE e.change_request_id = cr.id AND e.to_state = 'closed'),
                     cr.updated_at) > $1)
             )))
          OR
          (NOT EXISTS (SELECT 1 FROM verify_run_counts c WHERE c.verify_run_id = r.id)
           AND r.finalized_at < $2)
        )
        LIMIT $3
        """,
        [counted_cutoff, uncounted_cutoff, batch_size],
        log: false
      )

    Enum.reduce(rows, {0, 0}, fn [id, object_key], {expired, failed} ->
      case ObjectStore.delete(object_key) do
        result when result in [:ok, {:error, :not_found}] ->
          Repo.update_all(from(a in Artifact, where: a.id == ^Ecto.UUID.load!(id)),
            set: [expired: true]
          )

          {expired + 1, failed}

        {:error, _reason} ->
          {expired, failed + 1}
      end
    end)
  end
end
