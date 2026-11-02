defmodule GoodFlows.Pools.Members do
  @moduledoc """
  Member admission and fenced state transitions.

  Every transition is a conditional `UPDATE … WHERE id = ? AND state = ?`
  (plus `owner_id = ?` for job-owned states), so a slow or zombie worker
  that lost its claim changes nothing. Jobs claim a member by setting
  `owner_id` (only while it is `NULL`) together with a hard
  `operation_deadline_at`; finishing clears it.

  Releasing a leased member bumps `lease_generation`, which invalidates its
  workspace readiness and every report of the old lease; the member then
  goes to `resetting`, or directly to `destroying` when it is stale, beyond
  `max_members`, or of a credential namespace no open session needs.
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Pools
  alias GoodFlows.Pools.{Config, Credentials, Events, Member, Pool, Session}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Sprites

  @name_attempts 5

  @doc """
  Inserts a `provisioning` member for `pool` (whose row the caller holds
  locked) with the pool's current `setup_version` and the account's
  current credential snapshot. The name is retried on a collision; the
  insert uses `ON CONFLICT (name) DO NOTHING`, so a collision never aborts
  the caller's transaction.
  """
  @spec admit_provision(Pool.t(), %{token: String.t(), fingerprint: binary()}) ::
          {:ok, Member.t()} | {:error, :name_collision}
  def admit_provision(%Pool{} = pool, credential, attempt \\ 1) do
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      account_id: pool.account_id,
      pool_id: pool.id,
      name: name_generator().(),
      state: "provisioning",
      setup_version: pool.setup_version,
      credential_fingerprint: credential.fingerprint,
      credential_snapshot: credential.token,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Member, [row],
           on_conflict: :nothing,
           conflict_target: :name,
           returning: true,
           log: false
         ) do
      {1, [member]} -> {:ok, member}
      {0, []} when attempt < @name_attempts -> admit_provision(pool, credential, attempt + 1)
      {0, []} -> {:error, :name_collision}
    end
  end

  # Tests replace the generator to force a collision.
  defp name_generator,
    do: Application.get_env(:good_flows, :pool_member_name_generator, &Member.generate_name/0)

  @doc """
  Claims a member in `state` for a job run by `owner_id`: sets the owner
  and the hard operation deadline while no other owner holds it.
  """
  @spec claim(Ecto.UUID.t(), String.t(), String.t(), :provision | :reset | :destroy) ::
          {:ok, Member.t()} | :not_claimable
  def claim(member_id, state, owner_id, kind) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, Config.member_operation_deadline_ms(kind), :millisecond)

    Member
    |> where([m], m.id == ^member_id and m.state == ^state and is_nil(m.owner_id))
    |> select([m], m)
    |> Repo.update_all(
      set: [owner_id: owner_id, operation_deadline_at: deadline, updated_at: now]
    )
    |> case do
      {1, [member]} -> {:ok, member}
      {0, _} -> :not_claimable
    end
  end

  @doc """
  Fenced transition: updates the member only while it is in `from` and
  (when `owner_id` is not `:any`) owned by `owner_id`. Returns `:ok` or
  `:stale`.
  """
  @spec transition(Ecto.UUID.t(), String.t(), String.t() | :any | nil, keyword()) :: :ok | :stale
  def transition(member_id, from, owner_id, set) do
    query = where(Member, [m], m.id == ^member_id and m.state == ^from)

    query =
      case owner_id do
        :any -> query
        nil -> where(query, [m], is_nil(m.owner_id))
        owner -> where(query, [m], m.owner_id == ^owner)
      end

    case Repo.update_all(query, set: Keyword.put_new(set, :updated_at, DateTime.utc_now())) do
      {1, _} -> :ok
      {0, _} -> :stale
    end
  end

  @doc """
  Releases members leased to `session_id` (all of them, or `member_ids`):
  each goes to `resetting` or `destroying` with a new `lease_generation`
  and its job is enqueued after commit. The decision runs under the pool
  row lock (`release_locked/2`). Returns the released members.
  """
  @spec release(Ecto.UUID.t(), [Ecto.UUID.t()] | :all) :: [Member.t()]
  def release(session_id, member_ids \\ :all) do
    {:ok, released} = Repo.transact(fn -> {:ok, release_locked(session_id, member_ids)} end)
    enqueue_released(released)
    released
  end

  @doc """
  The transactional half of `release/2`, for callers that combine it with
  other writes: locks the members' pool rows (then the member rows, the
  lock order grants use), transitions each member, and returns the released
  members. Must run inside a transaction; the caller enqueues the jobs with
  `enqueue_released/1` after commit.
  """
  @spec release_locked(Ecto.UUID.t(), [Ecto.UUID.t()] | :all) :: [Member.t()]
  def release_locked(session_id, member_ids) do
    query = where(Member, [m], m.session_id == ^session_id and m.state == "leased")
    query = if member_ids == :all, do: query, else: where(query, [m], m.id in ^member_ids)

    pools =
      query
      |> select([m], m.pool_id)
      |> distinct(true)
      |> Repo.all()
      |> Enum.sort()
      |> Enum.map(&lock_pool/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.id, &1})

    # Counts and the current credential fingerprint are read once per pool
    # (not per member); the count drops as members leave for destroying.
    facts = Map.new(pools, fn {id, pool} -> {id, pool_facts(pool)} end)

    query
    |> order_by([m], asc: m.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.flat_map_reduce(facts, &release_one(%{&1 | pool: Map.fetch!(pools, &1.pool_id)}, &2))
    |> elem(0)
  end

  defp release_one(member, facts) do
    {target, pool_facts} = release_target(member, Map.fetch!(facts, member.pool_id))

    case transition(member.id, "leased", :any,
           state: target,
           session_id: nil,
           owner_id: nil,
           lease_generation: member.lease_generation + 1,
           workspace_ready_generation: nil,
           leased_at: nil
         ) do
      :ok ->
        pool_facts =
          if target == "destroying",
            do: %{pool_facts | count: pool_facts.count - 1},
            else: pool_facts

        {[%{member | state: target, session_id: nil}], Map.put(facts, member.pool_id, pool_facts)}

      :stale ->
        {[], facts}
    end
  end

  defp pool_facts(%Pool{} = pool) do
    current_fp =
      case Credentials.current(pool.account_id) do
        {:ok, %{fingerprint: fp}} -> fp
        _other -> nil
      end

    %{count: member_count(pool.id), current_fp: current_fp, needed: %{}}
  end

  @doc "Enqueues the reset or destroy job of each member released by `release_locked/2`."
  @spec enqueue_released([Member.t()]) :: :ok
  def enqueue_released(members) do
    Enum.each(members, &enqueue(&1.state, &1.id))
  end

  @doc "Locks and returns a pool row (`SELECT … FOR UPDATE`), or nil. Inside a transaction."
  @spec lock_pool(Ecto.UUID.t() | nil) :: Pool.t() | nil
  def lock_pool(nil), do: nil
  def lock_pool(pool_id), do: Pool |> where(id: ^pool_id) |> lock("FOR UPDATE") |> Repo.one()

  @doc """
  Where a released member goes: `destroying` when it is stale, the pool is
  being deleted or is over `max_members`, or its credential namespace is
  no longer current and no open session needs it; otherwise `resetting`.
  Callers hold the pool row lock, so the member count is stable.
  """
  @spec release_target(Member.t()) :: String.t()
  def release_target(%Member{pool: %Pool{} = pool} = member),
    do: member |> release_target(pool_facts(pool)) |> elem(0)

  defp release_target(%Member{pool: %Pool{} = pool} = member, facts) do
    cond do
      pool.deleting_at ->
        {"destroying", facts}

      Pools.stale?(member, pool) ->
        {"destroying", facts}

      facts.count > pool.max_members ->
        {"destroying", facts}

      member.credential_fingerprint == facts.current_fp ->
        {"resetting", facts}

      true ->
        fp = member.credential_fingerprint
        needed? = Map.get_lazy(facts.needed, fp, fn -> namespace_needed?(member) end)
        facts = %{facts | needed: Map.put(facts.needed, fp, needed?)}
        {if(needed?, do: "resetting", else: "destroying"), facts}
    end
  end

  # Members that will remain: rows already being destroyed do not count.
  defp member_count(pool_id),
    do:
      Repo.aggregate(
        where(Member, [m], m.pool_id == ^pool_id and m.state != "destroying"),
        :count
      )

  defp namespace_needed?(%Member{pool_id: pool_id, credential_fingerprint: fingerprint}) do
    Session
    |> where([s], s.pool_id == ^pool_id and s.status in ^Session.open_statuses())
    |> where([s], s.credential_fingerprint == ^fingerprint)
    |> Repo.exists?()
  end

  @doc "Marks a member `broken` from any state (fenced on `from`), recording `error`."
  @spec break(Member.t(), String.t(), String.t() | :any | nil, String.t()) :: :ok | :stale
  def break(%Member{} = member, from, owner_id, error) do
    result =
      transition(member.id, from, owner_id,
        state: "broken",
        owner_id: nil,
        session_id: nil,
        last_error: String.slice(error, 0, 1_000),
        failures: member.failures + 1
      )

    if result == :ok, do: Events.nudge(member.pool_id)
    result
  end

  @doc "Enqueues the job for a member in `provisioning`, `resetting`, or `destroying`."
  @spec enqueue(String.t(), Ecto.UUID.t()) :: :ok
  def enqueue(state, member_id) do
    job =
      case state do
        "provisioning" -> GoodFlows.Pools.ProvisionMemberJob
        "resetting" -> GoodFlows.Pools.ResetMemberJob
        "destroying" -> GoodFlows.Pools.DestroyMemberJob
      end

    case PgFlow.enqueue(job, %{"member_id" => member_id}) do
      {:ok, _run_id} ->
        :ok

      {:error, reason} ->
        # The reconciler re-enqueues members left without a job.
        Logger.warning("Pools: could not enqueue #{inspect(job)}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Pools: could not enqueue a member job: #{Exception.message(error)}")
      :ok
  end

  @doc "The member's Sprites client, built from its creation-credential snapshot."
  @spec client(Member.t()) :: Sprites.client()
  def client(%Member{credential_snapshot: token}) when is_binary(token),
    do: Sprites.client(token)

  @doc "Reloads a member with its credential snapshot (never logged)."
  @spec get(Ecto.UUID.t()) :: Member.t() | nil
  def get(member_id), do: Repo.get(Member, member_id, log: false)
end
