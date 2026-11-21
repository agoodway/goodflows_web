defmodule GoodFlows.MergeLeases do
  @moduledoc """
  Merge slot leases (the `merge-coordination` capability): at most one
  active lease per project and target branch, held by one change request
  while its client merges on the Git host. The server never merges.

  `acquire/3` runs in one transaction. It takes a transaction-level
  advisory lock on the slot (project, target branch), so two acquires for
  the same slot serialize and exactly one can win, and the partial unique
  index `merge_leases_active_slot_index` backs that up. It then locks the
  change request rows it touches (`FOR UPDATE`, in `number` order): the
  acquiring one, and the holder of an active lease past its `expires_at`,
  which it marks `expired` (such a lease holds no slot). The change
  request must be `open` (`not_open`), at the named head (`stale_head`),
  and its stored verdict at that head `mergeable` (`not_mergeable`); a live
  lease of another change request or key is `slot_taken`, and the same key
  asking again for the change request that holds the lease gets that
  lease back (`:retry`, nothing recorded). A new lease expires
  `merge.lease_ttl` (policy current at acquire, default 10 minutes) later.

  `heartbeat/3` moves `expires_at` of an active, unexpired lease to now
  plus its TTL, with no overall cap; `release/3` releases it with
  `release_reason: "released"`. Both are `lease_not_active` for an unknown,
  released or expired lease ID. `release_held/3` (called by
  `GoodFlows.ChangeRequests` when a change request is merged or closed)
  releases a held lease, or expires one past its time. `expire_due/1`
  (run by `GoodFlows.MergeLeases.ExpiryJob`) marks every active lease past
  its `expires_at` `expired` with `UPDATE … WHERE state = 'active'`, so
  each lease expires once.

  Lock order in every path: the slot advisory lock (acquire only), change
  request rows, lease rows, then `GoodFlows.ProjectEvents.record/5`. No
  path locks the project row. Change request rows are locked in `number`
  order, the order of every multi-row change request lock in
  `GoodFlows.ChangeRequests`. A parent's number is lower than its
  child's and numbers never change, so the order is parent-first without
  reading `parent_id`. Each change records its `lease_acquired`,
  `lease_renewed`, `lease_expired` or `lease_released` event in the same
  transaction, with the lease's change request as `number` and the
  request's key as `actor` (nil for expiry), and recomputes the change
  request's verdict (`GoodFlows.ChangeRequests.recompute/2`), since the
  merge-result check depends on the held lease. A merge's release does not
  recompute: the change request is `merged` and its verdict is frozen.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, Params, Verdict}
  alias GoodFlows.MergeLeases.Lease
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.Document

  @typedoc "A `409` with its `error` value and extra fields."
  @type conflict :: {:coded_conflict, String.t(), map()}

  @typedoc "A lease that ended with a merge or close: released, or expired past its time."
  @type ended :: {:released | :expired, Lease.t()}

  @doc """
  Acquires the merge slot of `change_request`'s project and target branch
  from a normalized body (`head`, `base`). Returns `{:ok, :created,
  lease}`, `{:ok, :retry, lease}`, `{:error, {:invalid_body, errors}}` or
  `{:error, {:coded_conflict, error, extra}}`.
  """
  @spec acquire(ChangeRequest.t(), ApiKey.t(), term()) ::
          {:ok, :created | :retry, Lease.t()}
          | {:error, {:invalid_body, map()} | conflict()}
  def acquire(%ChangeRequest{} = change_request, %ApiKey{} = api_key, body) do
    with {:ok, attrs} <- Params.acquire(body) do
      acquire_slot(change_request, api_key, attrs, 3)
    end
  end

  # A retarget between reading the branch and locking the row moves the
  # slot; the attempt is retried with the new branch.
  defp acquire_slot(change_request, api_key, attrs, attempts) do
    fresh = Repo.get!(ChangeRequest, change_request.id)

    case Repo.transaction(fn -> acquire_locked(fresh, api_key, attrs) end) do
      {:ok, {status, lease}} ->
        {:ok, status, lease}

      {:error, :target_moved} when attempts > 1 ->
        acquire_slot(change_request, api_key, attrs, attempts - 1)

      {:error, :target_moved} ->
        moved_result(change_request, api_key, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # After every attempt lost a race with a retarget or a changing slot
  # holder, the answer comes from the change request as read now, in the
  # order of `acquire_locked/3`: `not_open`, `stale_head`, then the live
  # lease of its current slot (the caller's own is the `:retry`), else
  # `slot_taken` without a holder.
  defp moved_result(change_request, api_key, attrs) do
    fresh = Repo.get!(ChangeRequest, change_request.id)
    lease = active_lease(fresh.project_id, fresh.target_branch)
    lease = if lease && not expired?(lease, DateTime.utc_now()), do: lease

    cond do
      fresh.state != "open" -> {:error, {:coded_conflict, "not_open", %{}}}
      fresh.head != attrs.head -> {:error, {:coded_conflict, "stale_head", %{head: fresh.head}}}
      lease == nil -> {:error, {:coded_conflict, "slot_taken", %{}}}
      retry?(lease, fresh, api_key, attrs) -> {:ok, :retry, lease}
      true -> {:error, slot_taken(lease)}
    end
  end

  defp acquire_locked(change_request, api_key, attrs) do
    branch = change_request.target_branch
    lock_slot(change_request.project_id, branch)
    now = DateTime.utc_now()

    stale_holder = stale_holder(change_request.project_id, branch, now)
    locked = lock_change_requests(Enum.uniq([change_request.id | stale_holder]))
    change_request = Map.fetch!(locked, change_request.id)

    if change_request.target_branch != branch, do: Repo.rollback(:target_moved)
    check_acquirable(change_request, attrs)

    case lock_active_lease(change_request.project_id, branch) do
      nil -> create(change_request, api_key, attrs, now, [])
      %Lease{} = lease -> take_slot(lease, locked, change_request, api_key, attrs, now)
    end
  end

  # The change request holding an active lease past its `expires_at`, as a
  # list of at most one ID, so its row is locked before the lease is expired.
  defp stale_holder(project_id, branch, now) do
    case active_lease(project_id, branch) do
      %Lease{} = lease -> if expired?(lease, now), do: [lease.change_request_id], else: []
      nil -> []
    end
  end

  defp take_slot(lease, locked, change_request, api_key, attrs, now) do
    cond do
      expired?(lease, now) and Map.has_key?(locked, lease.change_request_id) ->
        expire!(lease)
        create(change_request, api_key, attrs, now, [lease])

      expired?(lease, now) ->
        Repo.rollback(:target_moved)

      retry?(lease, change_request, api_key, attrs) ->
        {:retry, lease}

      true ->
        Repo.rollback(slot_taken(lease))
    end
  end

  defp check_acquirable(%ChangeRequest{state: state}, _attrs) when state != "open",
    do: Repo.rollback({:coded_conflict, "not_open", %{}})

  defp check_acquirable(%ChangeRequest{head: head}, %{head: named}) when head != named,
    do: Repo.rollback({:coded_conflict, "stale_head", %{head: head}})

  defp check_acquirable(_change_request, _attrs), do: :ok

  defp retry?(lease, change_request, api_key, attrs) do
    lease.change_request_id == change_request.id and lease.api_key_id == api_key.id and
      lease.head == attrs.head
  end

  defp slot_taken(lease) do
    {:coded_conflict, "slot_taken",
     %{
       holder: %{change_request: number(lease), expires_at: DateTime.to_iso8601(lease.expires_at)}
     }}
  end

  defp create(change_request, api_key, attrs, now, expired) do
    verdict = Repo.get(Verdict, change_request.id)

    state =
      if verdict && verdict.head == change_request.head, do: verdict.state, else: "pending"

    if state != "mergeable",
      do: Repo.rollback({:coded_conflict, "not_mergeable", %{state: state}})

    ttl = ttl_seconds(change_request.project_id)

    lease =
      %Lease{
        project_id: change_request.project_id,
        change_request_id: change_request.id,
        target_branch: change_request.target_branch,
        account_user_id: api_key.account_user_id,
        api_key_id: api_key.id,
        ttl_seconds: ttl,
        state: "active",
        acquired_at: now,
        expires_at: DateTime.add(now, ttl, :second)
      }
      |> Lease.acquire_changeset(attrs)
      |> Repo.insert!()

    Enum.each(expired, &record(&1, "lease_expired", nil))
    record(lease, "lease_acquired", api_key)
    Enum.each(expired, &recompute_holder/1)
    ChangeRequests.recompute(change_request)
    {:created, lease}
  end

  defp recompute_holder(%Lease{change_request_id: id}),
    do: ChangeRequests.recompute(Repo.get!(ChangeRequest, id))

  @doc "The `merge.lease_ttl` of the project's current policy, in seconds."
  @spec ttl_seconds(Ecto.UUID.t()) :: pos_integer()
  def ttl_seconds(project_id) do
    ReviewPolicies.current(project_id).document
    |> Document.effective()
    |> get_in(["merge", "lease_ttl"])
    |> Document.lease_ttl_seconds()
  end

  @doc """
  Extends an active, unexpired lease of `project` to now plus its TTL.
  Returns `{:ok, lease}` or `{:error, {:coded_conflict,
  "lease_not_active", %{}}}`.
  """
  @spec heartbeat(Project.t(), ApiKey.t(), String.t()) :: {:ok, Lease.t()} | {:error, conflict()}
  def heartbeat(%Project{id: project_id}, %ApiKey{} = api_key, lease_id) do
    with {:ok, id} <- cast_id(lease_id) do
      Repo.transaction(fn -> extend(project_id, id, api_key) end)
    end
  end

  defp extend(project_id, id, api_key) do
    now = DateTime.utc_now()

    query =
      from l in Lease,
        where:
          l.id == ^id and l.project_id == ^project_id and l.state == "active" and
            l.expires_at > ^now,
        select: l,
        update: [
          set: [
            expires_at:
              fragment(
                "?::timestamp + make_interval(secs => ?)",
                type(^now, :utc_datetime_usec),
                l.ttl_seconds
              )
          ]
        ]

    case Repo.update_all(query, []) do
      {1, [lease]} ->
        record(lease, "lease_renewed", api_key)
        lease

      {0, _} ->
        Repo.rollback(not_active())
    end
  end

  @doc """
  Releases an active, unexpired lease of `project` with `release_reason:
  "released"` and recomputes its change request's verdict. Returns `:ok`
  or `{:error, {:coded_conflict, "lease_not_active", %{}}}`.
  """
  @spec release(Project.t(), ApiKey.t(), String.t()) :: :ok | {:error, conflict()}
  def release(%Project{id: project_id}, %ApiKey{} = api_key, lease_id) do
    with {:ok, id} <- cast_id(lease_id),
         %Lease{} = lease <- Repo.get_by(Lease, id: id, project_id: project_id),
         {:ok, _} <- Repo.transaction(fn -> release_locked(lease, api_key) end) do
      :ok
    else
      nil -> {:error, not_active()}
      error -> error
    end
  end

  defp release_locked(lease, api_key) do
    locked = lock_change_requests([lease.change_request_id])

    case end_lease(lease.id, :released, "released", DateTime.utc_now()) do
      {1, [lease]} ->
        record(lease, "lease_released", api_key)
        ChangeRequests.recompute(Map.fetch!(locked, lease.change_request_id))

      {0, _} ->
        Repo.rollback(not_active())
    end
  end

  @doc """
  Inside the caller's transaction, after it locked `change_request`'s row
  and before it records any event: releases its active lease with
  `reason` (`merged` or `closed`), or marks it `expired` when it is past
  `expires_at`. Returns what ended, for `record_ended/3`.
  """
  @spec release_held(ChangeRequest.t(), String.t(), DateTime.t()) :: [ended()]
  def release_held(%ChangeRequest{id: id}, reason, now) when reason in ~w(merged closed) do
    leases =
      Repo.all(
        from l in Lease,
          where: l.change_request_id == ^id and l.state == "active",
          order_by: l.id,
          lock: "FOR UPDATE"
      )

    Enum.flat_map(leases, fn lease ->
      {kind, result} =
        if expired?(lease, now),
          do: {:expired, end_lease(lease.id, :expired, nil, nil)},
          else: {:released, end_lease(lease.id, :released, reason, now)}

      case result do
        {1, [ended]} -> [{kind, ended}]
        {0, _} -> []
      end
    end)
  end

  @doc """
  Records the `lease_released` (actor `api_key`) and `lease_expired`
  (actor nil) events of leases returned by `release_held/3`.
  """
  @spec record_ended([ended()], ApiKey.t()) :: :ok
  def record_ended(ended, %ApiKey{} = api_key) do
    Enum.each(ended, fn
      {:released, lease} -> record(lease, "lease_released", api_key)
      {:expired, lease} -> record(lease, "lease_expired", nil)
    end)
  end

  @doc """
  The change request's active lease that has not passed `expires_at` at
  `now`, or nil.
  """
  @spec held(ChangeRequest.t(), DateTime.t()) :: Lease.t() | nil
  def held(%ChangeRequest{id: id}, now \\ DateTime.utc_now()) do
    Repo.one(
      from l in Lease,
        where: l.change_request_id == ^id and l.state == "active" and l.expires_at > ^now,
        limit: 1
    )
  end

  @doc """
  Marks every active lease past its `expires_at` at `now` as `expired`,
  one transaction per lease: it locks the change request row, runs
  `UPDATE … WHERE state = 'active'`, and only when that changed the row
  records `lease_expired` and recomputes the verdict. Returns how many
  leases expired.
  """
  @spec expire_due(DateTime.t()) :: non_neg_integer()
  def expire_due(now \\ DateTime.utc_now()) do
    Repo.all(
      from l in Lease,
        where: l.state == "active" and l.expires_at <= ^now,
        order_by: l.expires_at,
        select: {l.id, l.change_request_id}
    )
    |> Enum.count(fn {id, change_request_id} -> expire_one(id, change_request_id, now) end)
  end

  defp expire_one(id, change_request_id, now) do
    {:ok, expired?} =
      Repo.transaction(fn ->
        locked = lock_change_requests([change_request_id])

        query =
          from l in Lease,
            where: l.id == ^id and l.state == "active" and l.expires_at <= ^now,
            select: l,
            update: [set: [state: "expired"]]

        case Repo.update_all(query, []) do
          {1, [lease]} ->
            record(lease, "lease_expired", nil)
            ChangeRequests.recompute(Map.fetch!(locked, change_request_id))
            true

          {0, _} ->
            false
        end
      end)

    expired?
  end

  defp end_lease(id, :released, reason, now) do
    Repo.update_all(
      from(l in Lease,
        where: l.id == ^id and l.state == "active" and l.expires_at > ^now,
        select: l
      ),
      set: [state: "released", release_reason: reason]
    )
  end

  defp end_lease(id, :expired, nil, nil) do
    Repo.update_all(
      from(l in Lease, where: l.id == ^id and l.state == "active", select: l),
      set: [state: "expired"]
    )
  end

  defp expire!(%Lease{id: id}) do
    {1, _} = end_lease(id, :expired, nil, nil)
    :ok
  end

  defp expired?(%Lease{expires_at: expires_at}, now), do: not DateTime.after?(expires_at, now)

  defp active_lease(project_id, branch) do
    Repo.one(
      from l in Lease,
        where: l.project_id == ^project_id and l.target_branch == ^branch and l.state == "active"
    )
  end

  defp lock_active_lease(project_id, branch) do
    Repo.one(
      from l in Lease,
        where: l.project_id == ^project_id and l.target_branch == ^branch and l.state == "active",
        lock: "FOR UPDATE"
    )
  end

  # In `number` order, the order of every multi-row change request lock:
  # a parent's number is lower than its child's, so it is parent-first.
  defp lock_change_requests(ids) do
    Repo.all(from c in ChangeRequest, where: c.id in ^ids, order_by: c.number, lock: "FOR UPDATE")
    |> Map.new(&{&1.id, &1})
  end

  defp lock_slot(project_id, branch) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('merge_slot:' || $1 || ':' || $2, 0))",
      [project_id, branch],
      log: false
    )

    :ok
  end

  @doc "The number of the lease's change request."
  @spec number(Lease.t()) :: pos_integer()
  def number(%Lease{change_request_id: id}),
    do: Repo.one!(from c in ChangeRequest, where: c.id == ^id, select: c.number)

  defp record(%Lease{} = lease, type, api_key) do
    number = number(lease)

    data = %{
      "lease_id" => lease.id,
      "target_branch" => lease.target_branch,
      "expires_at" => DateTime.to_iso8601(lease.expires_at)
    }

    data =
      if type == "lease_released",
        do: Map.put(data, "release_reason", lease.release_reason),
        else: data

    ProjectEvents.record(lease.project_id, number, type, data, api_key)
  end

  defp cast_id(lease_id) do
    case Ecto.UUID.cast(lease_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, not_active()}
    end
  end

  defp not_active, do: {:coded_conflict, "lease_not_active", %{}}
end
