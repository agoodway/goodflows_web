defmodule GoodFlows.Pools.Reconciler do
  @moduledoc """
  Keeps every pool's members built, reset, and within capacity, and
  expires sessions. Runs `reconcile/2` every `reconcile_interval_ms` (15 s)
  and shortly after a `GoodFlows.Pools.Events.nudge/1` (pool change,
  release, session demand), from exactly one node: like
  `GoodFlows.Spry.ReaperScheduler`, every node starts one, and only the
  holder of a `:global` leader name acts. It is started next to the reaper
  scheduler in `GoodFlows.Application.pgflow_children/1`. A node with pools
  disabled leads only for the duration of one pass and then frees the
  name, so an enabled node takes over at its next tick.

  The reconciler only decides; provisioning, reset, and destruction run as
  PgFlow jobs. One tick:

    1. expires due sessions (`GoodFlows.Pools.Sessions.expire_due/2`); the
       scheduled tick flips them and winds them down (cancelling execs,
       releasing members) in supervised tasks, so a slow coordinator never
       holds up the pass
    2. recovers execs whose owner is confirmed lost or past its hard
       deadline (`error`/`owner_lost`, member reset) and members: job-owned
       members whose worker is confirmed lost or past its hard deadline
       (`provisioning`/`resetting` become `broken`, `destroying` is
       retried); leased members of an ended session once its owner is
       confirmed lost or past the recovery deadline; members left without a
       job (and with no pending one) are re-enqueued. Each distinct owner
       is probed once per pass, concurrently.
    3. deletes ended sessions (with their execs) older than
       `session_retention_ms`
    4. for a pool being deleted: destroys every member, then deletes the
       row; members that are `abandoned` (never destroyable) are forgotten
       with a log line naming each
    5. otherwise: destroys broken, stale idle, unneeded old-namespace idle,
       excess idle, and (with the pool's opt-in `idle_ttl_ms`) long-idle
       members above `min_ready` plus unmet demand (only idle ones, never
       leased), grants, and provisions `min_ready + unmet wants` (of
       sessions in the current credential namespace) minus idle and
       provisioning members, capped so the total (including broken,
       destroying, and abandoned rows) stays within `max_members`, and only
       after the pool's provisioning backoff (read under the pool lock).
       Provisioning pauses while the account has no credential (and no
       warm member is retired for its namespace then); reset and
       destruction continue with member snapshots.

  Each phase and each pool is isolated: an error is logged and the rest of
  the pass continues. While pools are disabled, steps 1-4 still run and
  broken members are still destroyed, so a rollback is cleaned up, but no
  member is granted, retired as stale, or provisioned.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias GoodFlows.Leadership
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
    Provisioner,
    Session,
    Sessions
  }

  alias GoodFlows.Repo

  @leader_name __MODULE__.Leader
  @nudge_delay_ms 200
  @requeue_after_ms 120_000
  @recovery_margin_ms 5 * 60_000
  @purge_batch 1_000
  @job_slugs %{
    "provisioning" => {"pool_member_provision", :provision},
    "resetting" => {"pool_member_reset", :reset},
    "destroying" => {"pool_member_destroy", :destroy}
  }

  @doc "Starts the reconciler. Options: `:interval_ms`, `:name`, `:leader_name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl GenServer
  def init(opts) do
    Events.subscribe(Events.reconcile_topic())

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, Config.reconcile_interval_ms()),
      leader_name: Keyword.get(opts, :leader_name, @leader_name),
      pending: false
    }

    Process.send_after(self(), :tick, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    run(state)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:pools_nudge, _pool}, %{pending: true} = state), do: {:noreply, state}

  def handle_info({:pools_nudge, _pool}, state) do
    Process.send_after(self(), :nudged, @nudge_delay_ms)
    {:noreply, %{state | pending: true}}
  end

  def handle_info(:nudged, state) do
    run(state)
    {:noreply, %{state | pending: false}}
  end

  def handle_info({:global_name_conflict, _name}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp run(state) do
    if Leadership.claim(state.leader_name) do
      try do
        # Through the module, so tests can observe the pass.
        __MODULE__.reconcile(DateTime.utc_now(), wind_down: :async)
      after
        # A node with pools disabled only cleans up; it must not keep the
        # name from an enabled node.
        unless Config.enabled?(), do: Leadership.release(state.leader_name)
      end
    end
  rescue
    error -> Logger.error("Pools reconciler tick failed: #{Exception.message(error)}")
  end

  @doc """
  One reconciliation pass over every pool. Returns a summary.

  Options: `wind_down: :sync | :async` (default `:sync`): whether expired
  sessions are wound down inside the pass or in supervised tasks (the
  scheduled tick uses `:async`).
  """
  @spec reconcile(DateTime.t(), keyword()) :: map()
  def reconcile(now \\ DateTime.utc_now(), opts \\ []) do
    enabled? = Config.enabled?()
    wind_down = Keyword.get(opts, :wind_down, :sync)

    expired = isolated("session expiry", [], fn -> Sessions.expire_due(now, wind_down) end)
    recovered = isolated("member recovery", 0, fn -> recover_members(now) end)
    purged = isolated("session retention", 0, fn -> purge_sessions(now) end)

    pools =
      Pool
      |> order_by([p], asc: p.inserted_at)
      |> Repo.all()
      |> Enum.map(fn pool ->
        isolated("pool #{pool.id}", %{pool: pool.slug, failed: true}, fn ->
          reconcile_pool(pool, now, enabled?)
        end)
      end)

    %{
      enabled: enabled?,
      expired: length(expired),
      recovered: recovered,
      purged: purged,
      pools: pools
    }
  end

  defp isolated(what, fallback, fun) do
    fun.()
  rescue
    error ->
      Logger.error("Pools reconciler: #{what} failed: #{Exception.message(error)}")
      fallback
  end

  ## Member recovery

  defp recover_members(now) do
    running_owners =
      Exec |> where([e], e.status == "running") |> select([e], e.owner_id) |> Repo.all()

    job_owned =
      Member
      |> where(
        [m],
        m.state in ["provisioning", "resetting", "destroying"] and not is_nil(m.owner_id)
      )
      |> Repo.all()

    leases = ended_leases()

    # Each distinct owner is probed once, concurrently.
    probes = probe_all(running_owners ++ Enum.map(job_owned, & &1.owner_id), &OwnerRPC.probe/1)
    statuses = probe_all(Enum.map(leases, fn {_m, s} -> s && s.owner_id end), &OwnerRPC.status/1)
    lost? = fn owner_id -> lookup(probes, owner_id, &OwnerRPC.probe/1) == :lost end

    now
    |> Execs.lost_running(lost?)
    |> Enum.each(&Execs.recover_lost(&1.id))

    recovered_jobs =
      Enum.count(job_owned, &(worker_gone?(&1, now, lost?) and recover_job_owned_member(&1)))

    recovered_leases =
      Enum.count(leases, fn {member, session} -> recover_lease(member, session, now, statuses) end)

    recovered_jobs + recovered_leases + requeue_orphans(now)
  end

  defp probe_all(owner_ids, probe) do
    ids = owner_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    ids
    |> Task.async_stream(probe,
      max_concurrency: 16,
      timeout: Config.owner_rpc_timeout_ms() + 2_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(ids)
    |> Map.new(fn
      {{:ok, status}, id} -> {id, status}
      {{:exit, _timeout}, id} -> {id, :unknown}
    end)
  end

  defp lookup(probes, owner_id, probe),
    do: Map.get_lazy(probes, owner_id, fn -> probe.(owner_id) end)

  defp recover_job_owned_member(%Member{state: "destroying"} = member) do
    Members.transition(member.id, "destroying", member.owner_id,
      owner_id: nil,
      operation_deadline_at: nil
    ) == :ok
  end

  # A lost provision counts toward the pool's failure streak, like a failed one.
  defp recover_job_owned_member(%Member{state: "provisioning"} = member),
    do:
      Provisioner.fail_provision(member, member.owner_id, "the provisioning worker was lost") ==
        :ok

  defp recover_job_owned_member(%Member{state: from} = member),
    do: Members.break(member, from, member.owner_id, "the #{from} worker was lost") == :ok

  # A worker is confirmed gone when its node (this one or a connected one)
  # has no registration for it, or the boot differs. Unreachable is not gone.
  defp worker_gone?(member, now, lost?) do
    past_deadline? =
      member.operation_deadline_at != nil and
        DateTime.compare(now, member.operation_deadline_at) == :gt

    past_deadline? or lost?.(member.owner_id)
  end

  defp ended_leases do
    Member
    |> join(:left, [m], s in Session, on: s.id == m.session_id)
    |> where(
      [m, s],
      m.state == "leased" and (is_nil(s.id) or s.status not in ^Session.open_statuses())
    )
    |> select([m, s], {m, s})
    |> Repo.all()
  end

  defp recover_lease(member, nil, _now, _statuses) do
    Members.transition(member.id, "leased", :any,
      state: "resetting",
      session_id: nil,
      lease_generation: member.lease_generation + 1,
      workspace_ready_generation: nil
    ) == :ok and enqueued("resetting", member.id)
  end

  defp recover_lease(member, session, now, statuses) do
    recovery_ms = Config.exec_max_ms() + @recovery_margin_ms

    safe? =
      lookup(statuses, session.owner_id, &OwnerRPC.status/1) == :lost or
        (session.ended_at && DateTime.diff(now, session.ended_at, :millisecond) > recovery_ms)

    safe? and Members.release(session.id, [member.id]) != []
  end

  defp requeue_orphans(now) do
    cutoff = DateTime.add(now, -@requeue_after_ms, :millisecond)

    Member
    |> where([m], m.state in ["provisioning", "resetting", "destroying"] and is_nil(m.owner_id))
    |> where([m], m.updated_at < ^cutoff)
    |> where([m], is_nil(m.next_attempt_at) or m.next_attempt_at <= ^now)
    |> Repo.all()
    |> Enum.reject(&job_pending?(&1, now))
    |> Enum.count(fn member ->
      Members.transition(member.id, member.state, nil, []) == :ok and
        enqueued(member.state, member.id)
    end)
  end

  # A job queued behind others (all workers busy) has not claimed its
  # member yet; enqueueing another would only pile up duplicates. A run
  # older than the operation's hard deadline is not trusted to be pending.
  defp job_pending?(member, now) do
    {slug, kind} = Map.fetch!(@job_slugs, member.state)
    since = DateTime.add(now, -Config.member_operation_deadline_ms(kind), :millisecond)

    {:ok, count} =
      PgFlow.Runs.count(Repo,
        flow_slug: slug,
        status: :started,
        started_after: since,
        input_contains: %{"member_id" => member.id}
      )

    count > 0
  rescue
    _error -> false
  end

  defp enqueued(state, member_id) do
    Members.enqueue(state, member_id)
    true
  end

  ## Retention

  defp purge_sessions(now) do
    cutoff = DateTime.add(now, -Config.session_retention_ms(), :millisecond)

    ids =
      Session
      |> where([s], s.status not in ^Session.open_statuses() and s.ended_at < ^cutoff)
      |> select([s], s.id)
      |> limit(@purge_batch)

    # Execs go with their session (ON DELETE CASCADE).
    {count, _} = Repo.delete_all(where(Session, [s], s.id in subquery(ids)))
    count
  end

  ## Pools

  defp reconcile_pool(%Pool{deleting_at: deleting_at} = pool, _now, _enabled?)
       when not is_nil(deleting_at) do
    members = Repo.all(where(Member, pool_id: ^pool.id))

    for member <- members, member.state in ["idle", "broken"], do: destroy(member)

    {abandoned, remaining} = Enum.split_with(members, &(&1.state == "abandoned"))

    if remaining == [] do
      forget_abandoned(pool, abandoned)

      {count, _} =
        Repo.delete_all(where(Pool, [p], p.id == ^pool.id and not is_nil(p.deleting_at)))

      %{pool: pool.slug, deleted: count == 1}
    else
      %{pool: pool.slug, destroying: length(remaining)}
    end
  end

  # Disabled: only broken members are destroyed; nothing is granted,
  # retired as stale, or provisioned.
  defp reconcile_pool(%Pool{} = pool, _now, false) do
    destroyed =
      Member
      |> where([m], m.pool_id == ^pool.id and m.state == "broken")
      |> Repo.all()
      |> Enum.count(&destroy/1)

    %{pool: pool.slug, retired: destroyed, provisioned: 0}
  end

  defp reconcile_pool(%Pool{} = pool, now, true) do
    credential = Credentials.current(pool.account_id)

    current_fp =
      case credential do
        {:ok, %{fingerprint: fp}} -> fp
        {:error, :no_credential} -> nil
      end

    # Retiring idle members runs under the pool row lock, like grants, so
    # a member is never moved to destroying while a grant leases it, and
    # the excess count is computed from a stable member set.
    {:ok, {destroyed, total}} =
      Repo.transact(fn ->
        case Members.lock_pool(pool.id) do
          %Pool{} = locked ->
            members = Repo.all(where(Member, pool_id: ^pool.id))
            retired = retire(locked, members, current_fp, open_sessions(pool.id), now)
            {:ok, {retired, length(members)}}

          nil ->
            {:ok, {[], 0}}
        end
      end)

    Enum.each(destroyed, &Members.enqueue("destroying", &1.id))

    Grants.grant(pool.id)
    provisioned = provision(pool, credential)

    %{
      pool: pool.slug,
      retired: length(destroyed),
      provisioned: provisioned,
      members: total + provisioned
    }
  end

  # The pool is gone; abandoned members' sprites could never be destroyed
  # with their creation credential. Their rows go with a record of each.
  defp forget_abandoned(_pool, []), do: :ok

  defp forget_abandoned(pool, abandoned) do
    for member <- abandoned do
      Logger.error(
        "Pools: forgetting abandoned member #{member.name} of deleted pool #{pool.id} " <>
          "(#{member.last_error}); its sprite may still exist and must be removed in Sprites"
      )
    end

    ids = Enum.map(abandoned, & &1.id)
    Repo.delete_all(where(Member, [m], m.id in ^ids and m.state == "abandoned"))
  end

  defp open_sessions(pool_id) do
    Session
    |> where([s], s.pool_id == ^pool_id and s.status in ^Session.open_statuses())
    |> Repo.all()
  end

  defp retire(pool, members, current_fp, open_sessions, now) do
    needed_fps =
      open_sessions
      |> Enum.filter(&(&1.granted_count < &1.wanted))
      |> MapSet.new(& &1.credential_fingerprint)

    idle = Enum.filter(members, &(&1.state == "idle"))

    # Without a credential there is no current namespace: no warm member
    # is retired for being in another one (only stale ones are).
    unneeded =
      Enum.filter(idle, fn member ->
        Pools.stale?(member, pool) or
          (current_fp != nil and member.credential_fingerprint != current_fp and
             not MapSet.member?(needed_fps, member.credential_fingerprint))
      end)

    broken = Enum.filter(members, &(&1.state == "broken"))
    kept_idle = idle -- unneeded
    leaving = Enum.count(members, &(&1.state == "destroying")) + length(unneeded) + length(broken)
    excess = max(length(members) - leaving - pool.max_members, 0)

    excess_idle =
      kept_idle |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime}) |> Enum.take(excess)

    long_idle = long_idle(pool, kept_idle -- excess_idle, open_sessions, now)

    Enum.filter(broken ++ unneeded ++ excess_idle ++ long_idle, &mark_destroying/1)
  end

  # Opt-in idle shrink: idle members past the pool's `idle_ttl_ms` are
  # retired, longest idle first, while more than `min_ready` plus the
  # unmet demand of open sessions would remain idle.
  defp long_idle(%Pool{idle_ttl_ms: nil}, _idle, _sessions, _now), do: []

  defp long_idle(%Pool{idle_ttl_ms: ttl} = pool, idle, open_sessions, now) do
    cutoff = DateTime.add(now, -ttl, :millisecond)
    demand = open_sessions |> Enum.map(&max(&1.wanted - &1.granted_count, 0)) |> Enum.sum()
    surplus = max(length(idle) - (pool.min_ready + demand), 0)

    idle
    |> Enum.map(&{&1, &1.idle_since || &1.updated_at})
    |> Enum.filter(fn {_member, since} -> DateTime.compare(since, cutoff) == :lt end)
    |> Enum.sort_by(fn {_member, since} -> since end, DateTime)
    |> Enum.take(surplus)
    |> Enum.map(&elem(&1, 0))
  end

  defp mark_destroying(%Member{state: from} = member),
    do: Members.transition(member.id, from, nil, state: "destroying", owner_id: nil) == :ok

  defp destroy(%Member{state: from} = member) do
    if Members.transition(member.id, from, nil, state: "destroying", owner_id: nil) == :ok do
      Members.enqueue("destroying", member.id)
      true
    else
      false
    end
  end

  defp provision(_pool, {:error, :no_credential}), do: 0

  defp provision(pool, {:ok, credential}) do
    {:ok, admitted} = Repo.transact(fn -> {:ok, lock_and_admit(pool, credential)} end)

    Enum.each(admitted, &Members.enqueue("provisioning", &1.id))
    length(admitted)
  end

  # The backoff is read from the locked row: a failure recorded after this
  # pass read the pools is honored.
  defp lock_and_admit(pool, credential) do
    locked =
      Pool
      |> where(id: ^pool.id)
      |> where([p], is_nil(p.deleting_at))
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      is_nil(locked) -> []
      backing_off?(locked) -> []
      true -> admit(locked, credential)
    end
  end

  defp backing_off?(%Pool{next_provision_at: nil}), do: false

  defp backing_off?(%Pool{next_provision_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :gt

  defp admit(pool, credential) do
    members = Repo.all(where(Member, pool_id: ^pool.id))
    fp = credential.fingerprint

    unmet =
      pool.id
      |> open_sessions()
      |> Enum.filter(&(&1.credential_fingerprint == fp))
      |> Enum.map(&max(&1.wanted - &1.granted_count, 0))
      |> Enum.sum()

    have =
      Enum.count(members, fn m ->
        m.credential_fingerprint == fp and
          ((m.state == "idle" and not Pools.stale?(m, pool)) or
             (m.state == "provisioning" and m.setup_version == pool.setup_version))
      end)

    capacity = pool.max_members - length(members)
    wanted = min(pool.min_ready + unmet - have, capacity)

    if wanted > 0,
      do: Enum.flat_map(1..wanted, fn _ -> admit_one(pool, credential) end),
      else: []
  end

  # A name collision after the bounded retries skips that admission; the
  # next pass tries again.
  defp admit_one(pool, credential) do
    case Members.admit_provision(pool, credential) do
      {:ok, member} -> [member]
      {:error, _reason} -> []
    end
  end
end
