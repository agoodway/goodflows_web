defmodule GoodFlows.Caches.Sweep do
  @moduledoc """
  One cache sweep, run by `GoodFlows.Caches.SweepJob` every 5 minutes:

  1. deletes reservations whose `expires_at` is past,
  2. deletes committed entries not accessed within the retention window
     (`:cache_retention_days`),
  3. deletes cache keys revoked or expired more than 7 days ago,
  4. deletes up to one batch of queued objects whose `delete_after` (the
     expiry of their row's upload URL) is more than 60 seconds past, a
     margin for clock skew between nodes and the store, from object storage,
     and removes each queue row once the store confirms (or reports the
     object already gone). A failed delete stays queued for a later sweep.
     Step 4 stops starting deletes after a time budget (200 seconds by
     default), so a slow store cannot push a sweep past `SweepJob`'s
     300-second timeout; what is left stays queued.

  Steps 1 to 3 delete in batches (1,000 rows by default) until nothing is
  left. Every deleted entry queues its object (database trigger), so step 4
  catches up on the next sweeps. Sweeps are idempotent. Without a cache
  bucket step 4 is skipped, since objects cannot be deleted; steps 1 to 3
  still run, and the objects of the rows they delete stay queued until a
  bucket is configured again.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches
  alias GoodFlows.Caches.{Entry, ObjectStore}
  alias GoodFlows.Repo

  @batch_size 1_000
  @key_retention_days 7
  @time_budget_ms 200_000
  # Clock-skew margin: the sweep deletes an object only this long after its
  # `delete_after`, so a sweep node whose clock runs ahead of the signing
  # node's or the store's cannot delete an object while its URL still works.
  @delete_grace_seconds 60

  @typedoc "Counts of one sweep."
  @type summary :: %{
          reservations_expired: non_neg_integer(),
          entries_evicted: non_neg_integer(),
          keys_deleted: non_neg_integer(),
          objects_deleted: non_neg_integer(),
          objects_failed: non_neg_integer()
        }

  @doc """
  Runs one sweep. Options: `:batch_size` (default 1,000) and
  `:time_budget_ms` (default 200,000), after which no further object delete
  starts.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    deadline = started + Keyword.get(opts, :time_budget_ms, @time_budget_ms)
    now = DateTime.utc_now()
    retention = DateTime.add(now, -Caches.setting(:cache_retention_days), :day)
    expired = where(Entry, [e], e.state == :reserved and e.expires_at < ^now)
    stale = where(Entry, [e], e.state == :committed and e.last_accessed_at < ^retention)

    reservations_expired = delete_in_batches(Entry, expired, batch_size, 0)
    entries_evicted = delete_in_batches(Entry, stale, batch_size, 0)
    keys_deleted = delete_in_batches(ApiKey, old_keys(now), batch_size, 0)

    {deleted, failed} =
      if ObjectStore.configured?(), do: delete_objects(batch_size, deadline), else: {0, 0}

    %{
      reservations_expired: reservations_expired,
      entries_evicted: entries_evicted,
      keys_deleted: keys_deleted,
      objects_deleted: deleted,
      objects_failed: failed
    }
  end

  defp old_keys(now) do
    key_cutoff = now |> DateTime.add(-@key_retention_days, :day) |> DateTime.truncate(:second)

    ApiKey
    |> where([k], k.type in ^ApiKey.cache_types())
    |> where(
      [k],
      (k.status == :revoked and k.updated_at < ^key_cutoff) or k.expires_at < ^key_cutoff
    )
  end

  defp delete_in_batches(schema, query, batch_size, total) do
    ids = query |> select([r], r.id) |> limit(^batch_size)
    {count, _rows} = schema |> where([r], r.id in subquery(ids)) |> Repo.delete_all()

    if count == batch_size,
      do: delete_in_batches(schema, query, batch_size, total + count),
      else: total + count
  end

  defp delete_objects(batch_size, deadline) do
    "cache_object_deletions"
    |> where([d], d.delete_after <= type(^delete_cutoff(), :utc_datetime_usec))
    |> order_by([d], asc: d.delete_after, asc: d.object_key)
    |> limit(^batch_size)
    |> select([d], d.object_key)
    |> Repo.all()
    |> Enum.reduce_while({0, 0}, fn object_key, {deleted, failed} ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, {deleted, failed}}
      else
        {:cont, delete_object(object_key, deleted, failed)}
      end
    end)
  end

  defp delete_cutoff, do: DateTime.add(DateTime.utc_now(), -@delete_grace_seconds, :second)

  defp delete_object(object_key, deleted, failed) do
    case ObjectStore.delete(object_key) do
      result when result in [:ok, {:error, :not_found}] ->
        "cache_object_deletions" |> where([d], d.object_key == ^object_key) |> Repo.delete_all()
        {deleted + 1, failed}

      {:error, _reason} ->
        {deleted, failed + 1}
    end
  end
end
