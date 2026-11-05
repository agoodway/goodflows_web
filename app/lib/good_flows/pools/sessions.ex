defmodule GoodFlows.Pools.Sessions do
  @moduledoc """
  Pool sessions: creation, ownership, wants, release, liveness, and expiry.

  Creating a session validates the body, finds the pool, requires the
  account's Sprites credential, then starts a supervised
  `GoodFlows.Pools.SessionCoordinator` on this node holding the captured
  credential in memory, and inserts the `waiting` row (with the
  coordinator's owner id and the creating API key) under the pool row lock
  shared with grants and pool deletion. A pool deleted meanwhile is
  `:not_found`.

  Only the creating key may use a session: another key of the account gets
  `:forbidden`, another account `:not_found`.

  Ending a session (`end_session/3`) is idempotent: the first caller flips
  the status, then running execs are cancelled through the coordinator
  (their `exit` events precede `session_ended`), members are released for
  reset, the coordinator stops (deleting its spool), and `session_ended`
  is broadcast. When the coordinator cannot be reached and is not
  confirmed lost, running execs are finalized from the database and the
  members stay leased until `GoodFlows.Pools.Reconciler` can recover them
  safely.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Pools

  alias GoodFlows.Pools.{
    Config,
    Credentials,
    Events,
    Exec,
    Execs,
    Grants,
    Member,
    Members,
    OwnerRPC,
    Pool,
    Session,
    SessionCoordinator,
    ShutdownDrain
  }

  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Executions

  @doc """
  Creates a session for `api_key` on the project's pool `pool_slug`.
  """
  @spec create(Account.t(), Project.t(), term(), ApiKey.t(), map()) ::
          {:ok, Session.t()}
          | {:error,
             :not_found
             | :draining
             | Ecto.Changeset.t()
             | {:unprocessable, String.t()}}
  def create(%Account{} = account, %Project{} = project, pool_slug, %ApiKey{} = api_key, attrs) do
    with {:ok, pool} <- Pools.fetch_pool(account, project, pool_slug),
         changeset =
           Session.create_changeset(
             %Session{},
             attrs,
             pool.max_members,
             Config.acquire_timeout_max_ms()
           ),
         :ok <- valid_or_error(changeset),
         {:ok, credential} <- credential(account.id),
         true <- ShutdownDrain.accepting?() || {:error, :draining} do
      start(account, project, pool, api_key, changeset, credential)
    end
  end

  defp valid_or_error(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_or_error(changeset), do: {:error, %{changeset | action: :validate}}

  defp credential(account_id) do
    case Credentials.current(account_id) do
      {:ok, credential} ->
        {:ok, credential}

      {:error, :no_credential} ->
        {:error, {:unprocessable, Credentials.missing_message("starting a session")}}
    end
  end

  defp start(account, project, pool, api_key, changeset, credential) do
    session_id = Ecto.UUID.generate()
    owner_id = Executions.new_owner_id()

    with {:ok, coordinator} <-
           SessionCoordinator.start(%{
             session_id: session_id,
             owner_id: owner_id,
             account_id: account.id,
             token: credential.token
           }) do
      insert = fn ->
        insert(session_id, owner_id, account, project, pool, api_key, changeset, credential)
      end

      with {:ok, session} <- insert_or_stop(coordinator, insert) do
        SessionCoordinator.activate(coordinator)
        Grants.try_grant(pool.id)
        Events.nudge(pool.id)
        {:ok, Repo.reload!(session)}
      end
    end
  end

  # The coordinator holds the captured token: it must not outlive a failed
  # (or raising) insert. It also stops itself if never activated.
  defp insert_or_stop(coordinator, insert) do
    result = insert.()
    unless match?({:ok, _}, result), do: SessionCoordinator.stop(coordinator)
    result
  rescue
    error ->
      SessionCoordinator.stop(coordinator)
      reraise error, __STACKTRACE__
  end

  defp insert(session_id, owner_id, account, project, pool, api_key, changeset, credential) do
    Repo.transact(fn ->
      case Pool
           |> where(id: ^pool.id)
           |> where([p], is_nil(p.deleting_at))
           |> lock("FOR UPDATE")
           |> Repo.one() do
        nil ->
          {:error, :not_found}

        %Pool{} ->
          now = DateTime.utc_now()
          max = Ecto.Changeset.get_field(changeset, :max_members)
          acquire_ms = Ecto.Changeset.get_field(changeset, :acquire_timeout_ms)

          changeset
          |> Ecto.Changeset.change(
            id: session_id,
            account_id: account.id,
            pool_id: pool.id,
            api_key_id: api_key.id,
            pool_slug: pool.slug,
            project_slug: project.slug,
            credential_fingerprint: credential.fingerprint,
            owner_id: owner_id,
            owner_lease_expires_at: DateTime.add(now, Config.disconnect_grace_ms(), :millisecond),
            status: "waiting",
            wanted: max,
            granted_count: 0,
            wanting_since: now,
            acquire_deadline_at: DateTime.add(now, acquire_ms, :millisecond),
            last_seen_at: now
          )
          |> Repo.insert()
      end
    end)
  end

  @doc "Fetches a session of the account (any key)."
  @spec get(Account.t(), term()) :: {:ok, Session.t()} | {:error, :not_found}
  def get(%Account{id: account_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Session{} = session <- Repo.get_by(Session, id: id, account_id: account_id) do
      {:ok, session}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Fetches a session for its creating key: another account's session is
  `:not_found`, another key's `:forbidden`.
  """
  @spec get_owned(Account.t(), ApiKey.t() | Ecto.UUID.t(), term()) ::
          {:ok, Session.t()} | {:error, :not_found | :forbidden}
  def get_owned(%Account{} = account, %ApiKey{id: key_id}, id), do: get_owned(account, key_id, id)

  def get_owned(%Account{} = account, key_id, id) do
    with {:ok, session} <- get(account, id) do
      if session.api_key_id == key_id, do: {:ok, session}, else: {:error, :forbidden}
    end
  end

  @doc "Members currently leased to the session, oldest grant first."
  @spec members(Ecto.UUID.t()) :: [Member.t()]
  def members(session_id) do
    Member
    |> where([m], m.session_id == ^session_id and m.state == "leased")
    |> order_by([m], asc: m.leased_at, asc: m.id)
    |> Repo.all()
  end

  @doc "Releases the session (`DELETE` or the channel `release` event). Idempotent."
  @spec release(Session.t()) :: :ok
  def release(%Session{} = session) do
    _ = end_session(session.id, "released", nil)
    :ok
  end

  @doc """
  Ends an open session as `released` (reason `nil`) or `expired` (with a
  reason). Returns `:ok`, or `:already_ended` when another caller ended it
  first.
  """
  @spec end_session(Ecto.UUID.t(), String.t(), String.t() | nil, :sync | :async) ::
          :ok | :already_ended
  def end_session(session_id, status, reason, wind_down \\ :sync)
      when status in ["released", "expired"] do
    now = DateTime.utc_now()

    Session
    |> where([s], s.id == ^session_id and s.status in ^Session.open_statuses())
    |> select([s], s)
    |> Repo.update_all(set: [status: status, end_reason: reason, ended_at: now, updated_at: now])
    |> case do
      {1, [session]} ->
        wind_down(session, wind_down)
        :ok

      {0, _} ->
        :already_ended
    end
  end

  # `:async` (the reconciler tick): the status flip above is the decision;
  # cancelling execs and releasing members, which can wait on a slow
  # coordinator, runs in a supervised task. A task lost with its node
  # leaves leased members of an ended session, which the reconciler
  # recovers once their owner is confirmed lost or past the deadline.
  defp wind_down(session, :sync), do: wind_down(session)

  defp wind_down(session, :async) do
    {:ok, _pid} =
      Task.Supervisor.start_child(GoodFlows.Spry.TaskSupervisor, fn -> wind_down(session) end)

    :ok
  end

  defp wind_down(%Session{} = session) do
    {exec_status, error_reason} =
      if session.end_reason == "session_owner_lost",
        do: {"error", "owner_lost"},
        else: {"cancelled", nil}

    owner_status =
      case OwnerRPC.call(
             session.owner_id,
             {:end_session, exec_status, error_reason},
             SessionCoordinator.stop_call_timeout_ms()
           ) do
        :ok -> :alive
        {:error, :owner_lost} -> :lost
        _unreachable -> :unknown
      end

    if owner_status != :alive, do: finalize_orphaned_execs(session.id, exec_status, error_reason)

    # Members are reset only once nothing can still drive them.
    if owner_status in [:alive, :lost], do: Members.release(session.id)

    Events.session_event(session.id, "session_ended", %{
      status: session.status,
      reason: session.end_reason
    })

    if session.pool_id, do: Events.nudge(session.pool_id)
  end

  defp finalize_orphaned_execs(session_id, status, error_reason) do
    for exec <- Execs.running(session_id) do
      duration = DateTime.diff(DateTime.utc_now(), exec.started_at, :millisecond)

      case Execs.finalize(exec.id, :any, %{
             status: status,
             error_reason: error_reason,
             duration_ms: duration
           }) do
        {:ok, exec} -> Events.exec_event(exec.id, "exit", Exec.exit_event(exec))
        :stale -> :ok
      end
    end
  end

  @doc """
  Releases one member held by the session. The session coordinator cancels
  the member's running exec and in-flight hydration and invalidates its
  reports, then (in the same coordinator call, so no new exec can be
  admitted in between) `release_member_now/2` resets the member and lowers
  `wanted` to at most the remaining holdings so it is not automatically
  replaced. Refused with `:unavailable` when the coordinator cannot be
  reached but is not confirmed lost.
  """
  @spec release_member(Session.t(), term()) :: :ok | {:error, :not_granted | :unavailable}
  def release_member(%Session{} = session, member_id) do
    with {:ok, member_id} <- Ecto.UUID.cast(member_id),
         %Member{} <- Repo.get_by(Member, id: member_id, session_id: session.id, state: "leased") do
      result =
        case OwnerRPC.call(
               session.owner_id,
               {:release_member, member_id},
               SessionCoordinator.stop_call_timeout_ms()
             ) do
          {:error, :owner_unavailable} -> {:error, :unavailable}
          # Nothing can still drive the member: release it from here.
          {:error, :owner_lost} -> release_member_now(session.id, member_id)
          result -> result
        end

      if result == :ok, do: Grants.try_grant(session.pool_id)
      result
    else
      _ -> {:error, :not_granted}
    end
  end

  @doc """
  Releases `member_id` from the session and recomputes its holdings, in one
  transaction under the pool and session row locks: `granted_count`
  becomes the number of members still leased to it and `wanted` at most
  that. Called by the session coordinator after cancelling the member's
  work (or by `release_member/2` once the coordinator is confirmed lost).
  """
  @spec release_member_now(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :not_granted}
  def release_member_now(session_id, member_id) do
    Repo.transact(fn ->
      with %Session{} = session <- lock_session(session_id),
           [_released] = released <- Members.release_locked(session_id, [member_id]) do
        holdings = leased_count(session_id)

        {1, _} =
          Session
          |> where(id: ^session.id)
          |> Repo.update_all(
            set: [
              granted_count: holdings,
              wanted: min(session.wanted, holdings),
              updated_at: DateTime.utc_now()
            ]
          )

        {:ok, released}
      else
        _ -> {:error, :not_granted}
      end
    end)
    |> case do
      {:ok, released} ->
        Members.enqueue_released(released)
        :ok

      {:error, :not_granted} ->
        {:error, :not_granted}
    end
  end

  # The pool row first, then the session row: the lock order of grants.
  defp lock_session(session_id) do
    with %Session{pool_id: pool_id} <- Repo.get(Session, session_id) do
      _pool = Members.lock_pool(pool_id)
      Session |> where(id: ^session_id) |> lock("FOR UPDATE") |> Repo.one()
    end
  end

  defp leased_count(session_id),
    do:
      Repo.aggregate(
        where(Member, [m], m.session_id == ^session_id and m.state == "leased"),
        :count
      )

  @doc """
  Sets the desired total holdings (0 to the session's `max_members`).
  Lowering never revokes members; raising starts a fresh waiting interval.
  """
  @spec set_wanted(Session.t(), term()) :: :ok | {:error, :invalid}
  def set_wanted(%Session{} = session, wanted)
      when is_integer(wanted) and wanted >= 0 do
    if wanted > session.max_members do
      {:error, :invalid}
    else
      now = DateTime.utc_now()

      {count, _} =
        Session
        |> where([s], s.id == ^session.id and s.status in ^Session.open_statuses())
        |> update([s],
          set: [
            wanted: ^wanted,
            wanting_since:
              fragment(
                "CASE WHEN ? > ? THEN ? ELSE ? END",
                ^wanted,
                s.wanted,
                ^now,
                s.wanting_since
              ),
            updated_at: ^now
          ]
        )
        |> Repo.update_all([])

      if count == 1 do
        Grants.try_grant(session.pool_id)
        Events.nudge(session.pool_id)
      end

      :ok
    end
  end

  def set_wanted(%Session{}, _wanted), do: {:error, :invalid}

  @doc """
  Records that a client of the session is joined. Ends the session with
  `key_revoked` when its creating key is gone, revoked, or expired.
  Returns `:ok` or `{:ended, status, reason}`.
  """
  @spec heartbeat(Ecto.UUID.t()) :: :ok | {:ended, String.t(), String.t() | nil}
  def heartbeat(session_id) do
    now = DateTime.utc_now()

    Session
    |> where([s], s.id == ^session_id and s.status in ^Session.open_statuses())
    |> select([s], s)
    |> Repo.update_all(set: [last_seen_at: now])
    |> case do
      {1, [session]} ->
        if key_valid?(session.api_key_id, now) do
          :ok
        else
          end_session(session.id, "expired", "key_revoked")
          ended(session.id)
        end

      {0, _} ->
        ended(session_id)
    end
  end

  defp ended(session_id) do
    case Repo.get(Session, session_id) do
      %Session{status: status, end_reason: reason} -> {:ended, status, reason}
      nil -> {:ended, "expired", nil}
    end
  end

  defp key_valid?(nil, _now), do: false

  defp key_valid?(key_id, now) do
    ApiKey
    |> where([k], k.id == ^key_id and k.status == :active)
    |> where([k], is_nil(k.expires_at) or k.expires_at > ^now)
    |> Repo.exists?()
  end

  @doc """
  Expires due sessions (reconciler tick), in this order: creating key
  gone/revoked/expired (`key_revoked`), no member by the acquisition
  deadline (`no_member_available`), owner confirmed lost or its lease
  lapsed (`session_owner_lost`), no client within the
  disconnect grace (`client_disconnected`), lifetime passed
  (`lifetime_exceeded`). Returns `[{session_id, reason}]`.
  """
  @spec expire_due(DateTime.t(), :sync | :async) :: [{Ecto.UUID.t(), String.t()}]
  def expire_due(now \\ DateTime.utc_now(), wind_down \\ :sync) do
    sessions =
      Session
      |> where([s], s.status in ^Session.open_statuses())
      |> Repo.all()

    owners = owner_statuses(sessions)
    valid_keys = valid_key_ids(sessions, now)

    Enum.flat_map(sessions, fn session ->
      reason = expiry_reason(session, Map.fetch!(owners, session.id), valid_keys, now)
      expire(session, reason, wind_down)
    end)
  end

  # One query for every session's creating key.
  defp valid_key_ids(sessions, now) do
    ids = sessions |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    ApiKey
    |> where([k], k.id in ^ids and k.status == :active)
    |> where([k], is_nil(k.expires_at) or k.expires_at > ^now)
    |> select([k], k.id)
    |> Repo.all()
    |> MapSet.new()
  end

  # Owners are probed concurrently, so one unreachable node delays a tick by
  # at most one RPC timeout instead of one per session.
  defp owner_statuses(sessions) do
    sessions
    |> Task.async_stream(&{&1.id, OwnerRPC.status(&1.owner_id)},
      max_concurrency: 16,
      timeout: Config.owner_rpc_timeout_ms() + 2_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(sessions)
    |> Map.new(fn
      {{:ok, {id, status}}, _session} -> {id, status}
      {{:exit, _timeout}, session} -> {session.id, :unknown}
    end)
  end

  defp expire(_session, nil, _wind_down), do: []

  defp expire(session, reason, wind_down) do
    case end_session(session.id, "expired", reason, wind_down) do
      :ok -> [{session.id, reason}]
      :already_ended -> []
    end
  end

  defp expiry_reason(session, owner_status, valid_keys, now) do
    grace = Config.disconnect_grace_ms()

    cond do
      not MapSet.member?(valid_keys, session.api_key_id) ->
        "key_revoked"

      is_nil(session.first_granted_at) and
          DateTime.compare(now, session.acquire_deadline_at) != :lt ->
        "no_member_available"

      owner_lost?(session, owner_status, now) ->
        "session_owner_lost"

      DateTime.diff(now, session.last_seen_at, :millisecond) > grace ->
        "client_disconnected"

      DateTime.diff(now, session.inserted_at, :millisecond) > Config.max_session_lifetime_ms() ->
        "lifetime_exceeded"

      true ->
        nil
    end
  end

  # The coordinator renews its lease to now + grace, so a lapsed lease
  # already means a full grace without renewal.
  defp owner_lost?(_session, :alive, _now), do: false
  defp owner_lost?(_session, :lost, _now), do: true
  defp owner_lost?(session, :unknown, now), do: lease_lapsed?(session, now)

  defp lease_lapsed?(%Session{owner_lease_expires_at: nil}, _now), do: true

  defp lease_lapsed?(%Session{owner_lease_expires_at: expires}, now),
    do: DateTime.compare(now, expires) == :gt

  @doc """
  Ends every open session whose coordinator belongs to this node and boot
  with `reason` (shutdown drain). Returns how many were ended.
  """
  @spec end_local_sessions(String.t()) :: non_neg_integer()
  def end_local_sessions(reason) do
    prefix = Executions.owner_prefix()

    Session
    |> where([s], s.status in ^Session.open_statuses())
    |> where([s], like(s.owner_id, ^"#{escape_like(prefix)}%"))
    |> select([s], s.id)
    |> Repo.all()
    |> Enum.count(&(end_session(&1, "expired", reason) == :ok))
  end

  defp escape_like(string), do: String.replace(string, ~w(\\ % _), &"\\#{&1}")

  @doc """
  Records the uploaded workspace on an open session owned by `owner_id`.
  Returns `:ok`, or `:stale` when the session ended or moved.
  """
  @spec mark_workspace_uploaded(Ecto.UUID.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | :stale
  def mark_workspace_uploaded(session_id, owner_id, bytes, sha256) do
    now = DateTime.utc_now()

    Session
    |> where([s], s.id == ^session_id and s.owner_id == ^owner_id)
    |> where([s], s.status in ^Session.open_statuses() and is_nil(s.workspace_uploaded_at))
    |> Repo.update_all(
      set: [
        workspace_uploaded_at: now,
        workspace_bytes: bytes,
        workspace_sha256: sha256,
        updated_at: now
      ]
    )
    |> case do
      {1, _} -> :ok
      {0, _} -> :stale
    end
  end

  @doc """
  Marks a member's workspace ready for `generation`, only while it is still
  leased to `session_id` under that lease generation, then announces
  `member_ready`.
  """
  @spec mark_member_ready(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()) :: :ok | :stale
  def mark_member_ready(member_id, session_id, generation) do
    Member
    |> where([m], m.id == ^member_id and m.session_id == ^session_id and m.state == "leased")
    |> where([m], m.lease_generation == ^generation)
    |> select([m], m)
    |> Repo.update_all(
      set: [workspace_ready_generation: generation, updated_at: DateTime.utc_now()]
    )
    |> case do
      {1, [member]} ->
        Events.session_event(session_id, "member_ready", %{
          member_id: member.id,
          name: member.name
        })

        :ok

      {0, _} ->
        :stale
    end
  end

  @doc """
  A member failed workspace hydration under `generation`: it is reset
  (`:reset`) or marked `broken` (`:broken`, missing or incompatible
  helper), announced as `member_lost`, and the session keeps its place in
  the grant queue (its `wanted` is unchanged, so a replacement is granted).
  """
  @spec member_lost(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer(), :reset | :broken, String.t()) ::
          :ok | :stale
  def member_lost(member_id, session_id, generation, outcome, error) do
    Repo.transact(fn ->
      with %Session{} <- lock_session(session_id),
           %Member{} = member <- lock_lost_member(member_id, session_id, generation),
           {:ok, released} <- lose(member, outcome, error) do
        {_, _} =
          Session
          |> where(id: ^session_id)
          |> Repo.update_all(set: [granted_count: leased_count(session_id)])

        {:ok, {member, released}}
      else
        _ -> {:error, :stale}
      end
    end)
    |> case do
      {:ok, {member, released}} ->
        Members.enqueue_released(released)

        Events.session_event(session_id, "member_lost", %{
          member_id: member.id,
          name: member.name,
          reason: error
        })

        Grants.try_grant(member.pool_id)
        Events.nudge(member.pool_id)
        :ok

      {:error, :stale} ->
        :stale
    end
  end

  defp lock_lost_member(member_id, session_id, generation) do
    Member
    |> where([m], m.id == ^member_id and m.session_id == ^session_id and m.state == "leased")
    |> where([m], m.lease_generation == ^generation)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lose(member, :broken, error) do
    case Members.break(member, "leased", :any, error) do
      :ok -> {:ok, []}
      :stale -> :stale
    end
  end

  defp lose(member, :reset, _error) do
    case Members.release_locked(member.session_id, [member.id]) do
      [_] = released -> {:ok, released}
      [] -> :stale
    end
  end

  @doc """
  Whether `member_id` is still leased to `session_id` under lease
  `generation`: the fence every workspace transfer attempt checks first.
  """
  @spec lease_current?(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()) :: boolean()
  def lease_current?(member_id, session_id, generation) do
    Member
    |> where([m], m.id == ^member_id and m.session_id == ^session_id and m.state == "leased")
    |> where([m], m.lease_generation == ^generation)
    |> Repo.exists?()
  end

  @doc "Renews the coordinator's owner lease; `:stale` once the session ended or moved."
  @spec renew_owner_lease(Ecto.UUID.t(), String.t()) :: :ok | :stale
  def renew_owner_lease(session_id, owner_id) do
    expires = DateTime.add(DateTime.utc_now(), Config.disconnect_grace_ms(), :millisecond)

    Session
    |> where([s], s.id == ^session_id and s.owner_id == ^owner_id)
    |> where([s], s.status in ^Session.open_statuses())
    |> Repo.update_all(set: [owner_lease_expires_at: expires])
    |> case do
      {1, _} -> :ok
      {0, _} -> :stale
    end
  end
end
