defmodule GoodFlows.Pools.Grants do
  @moduledoc """
  Grants idle members to waiting sessions of one pool.

  `grant/1` runs in one transaction holding `SELECT … FOR UPDATE` on the
  pool row (the same lock as session creation, pool deletion, member
  release, and exec admission), then on the candidate session and member
  rows (lock order: pool, sessions, members), so concurrent grants never
  assign a member twice and a session ending or a member being retired
  meanwhile is never overwritten. Each lease is still conditional on the
  member being `idle` and the session open, and increments
  `granted_count` in place.

  Eligible members are `idle`, not stale, and of the session's credential
  namespace. Sessions are open, hold fewer members than they want, have
  not passed their acquisition deadline without a first grant, and are
  ordered by
  `(granted_count = 0) DESC, wanting_since ASC, id ASC`: every session
  holding nothing is served before any holding session gets another
  member, and otherwise the one unmet the longest goes first. After each
  single assignment the session's `wanting_since` moves to the grant time
  and the order is recomputed, until no member or no wanting session fits.

  A session's first grant makes it `active` and sets `first_granted_at`,
  which is never cleared. After commit, each grant is broadcast as
  `member_granted` on the session topic.
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Pools
  alias GoodFlows.Pools.{Events, Member, Pool, Session}
  alias GoodFlows.Repo

  @doc "Grants what can be granted in `pool_id`. Returns `{session_id, member}` pairs."
  @spec grant(Ecto.UUID.t()) :: [{Ecto.UUID.t(), Member.t()}]
  def grant(pool_id) do
    {:ok, grants} =
      Repo.transact(fn ->
        case Pool |> where(id: ^pool_id) |> lock("FOR UPDATE") |> Repo.one() do
          %Pool{deleting_at: nil} = pool -> {:ok, assign(pool)}
          _missing_or_deleting -> {:ok, []}
        end
      end)

    for {session_id, member} <- grants do
      Events.session_event(session_id, "member_granted", %{
        member_id: member.id,
        name: member.name
      })
    end

    grants
  end

  @doc """
  `grant/1` for callers that must not crash on a database error (session
  creation after its row is committed, the session coordinator, channel
  handlers): a failure is logged, the reconciler is nudged to retry the
  grant, and nothing is returned.
  """
  @spec try_grant(Ecto.UUID.t() | nil) :: [{Ecto.UUID.t(), Member.t()}]
  def try_grant(nil), do: []

  def try_grant(pool_id) do
    grant(pool_id)
  rescue
    error ->
      Logger.warning("Pools: grant failed, the reconciler retries: #{Exception.message(error)}")
      Events.nudge(pool_id)
      []
  catch
    :exit, reason ->
      Logger.warning("Pools: grant failed, the reconciler retries: #{inspect(reason)}")
      Events.nudge(pool_id)
      []
  end

  defp assign(pool) do
    now = DateTime.utc_now()

    # Lock order everywhere: pool, then sessions, then members. The session
    # and member row locks keep a concurrent session end or member
    # retirement from changing them between this read and the lease below
    # (`lease/3` re-checks both anyway).
    sessions =
      Session
      |> where([s], s.pool_id == ^pool.id and s.status in ^Session.open_statuses())
      |> where([s], s.granted_count < s.wanted)
      |> where([s], not is_nil(s.first_granted_at) or s.acquire_deadline_at > ^now)
      |> order_by([s], asc: s.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    members =
      Member
      |> where([m], m.pool_id == ^pool.id and m.state == "idle")
      |> order_by([m], asc: m.inserted_at, asc: m.id)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.filter(&Pools.grantable?(&1, pool))

    loop(sessions, members, now, [])
  end

  defp loop(sessions, members, now, acc) do
    ordered = Enum.sort_by(sessions, &priority/1)

    case pick(ordered, members) do
      nil ->
        Enum.reverse(acc)

      {session, member} ->
        # Each grant in a batch gets a distinct, increasing time so that
        # "time since last grant" orders sessions granted in this pass too.
        at = DateTime.add(now, length(acc), :microsecond)
        members = Enum.reject(members, &(&1.id == member.id))

        {sessions, members, acc} =
          after_lease(lease(session, member, at), session, member, {sessions, members, acc})

        loop(sessions, members, now, acc)
    end
  end

  # The next round's candidates after one lease attempt (`member` is already
  # out of `members`).
  defp after_lease({:ok, leased_session, member}, _session, _member, {sessions, members, acc}) do
    sessions = for s <- sessions, s.id != leased_session.id, do: s

    sessions =
      if leased_session.granted_count < leased_session.wanted,
        do: [leased_session | sessions],
        else: sessions

    {sessions, members, [{leased_session.id, member} | acc]}
  end

  defp after_lease(:member_gone, _session, _member, state), do: state

  defp after_lease(:session_gone, session, member, {sessions, members, acc}),
    do: {for(s <- sessions, s.id != session.id, do: s), [member | members], acc}

  defp priority(%Session{} = s) do
    {if(s.granted_count == 0, do: 0, else: 1),
     DateTime.to_unix(s.wanting_since || s.inserted_at, :microsecond), s.id}
  end

  # The first session (in priority order) that has an eligible member.
  defp pick(sessions, members) do
    Enum.find_value(sessions, fn session ->
      case Enum.find(members, &(&1.credential_fingerprint == session.credential_fingerprint)) do
        nil -> nil
        member -> {session, member}
      end
    end)
  end

  # Both writes are conditional, so a member that left `idle` or a session
  # that ended since the read is skipped rather than overwritten. The
  # member is leased first; when the session turns out to be gone, that
  # lease is undone in the same transaction (nothing else can have seen
  # it). `granted_count` is incremented in place, never written from a read.
  defp lease(session, member, now) do
    case lease_member(member, session, now) do
      {:ok, leased} ->
        case lease_session(session, now) do
          {:ok, session} ->
            {:ok, session, leased}

          :session_gone ->
            {1, _} =
              Member
              |> where([m], m.id == ^member.id and m.state == "leased")
              |> Repo.update_all(
                set: [
                  state: "idle",
                  session_id: nil,
                  lease_generation: member.lease_generation,
                  workspace_ready_generation: member.workspace_ready_generation,
                  leased_at: member.leased_at,
                  updated_at: member.updated_at
                ]
              )

            :session_gone
        end

      :member_gone ->
        :member_gone
    end
  end

  defp lease_session(session, now) do
    Session
    |> where([s], s.id == ^session.id and s.status in ^Session.open_statuses())
    |> select([s], s)
    |> update([s],
      set: [
        status: "active",
        wanting_since: ^now,
        first_granted_at: coalesce(s.first_granted_at, ^now),
        updated_at: ^now
      ],
      inc: [granted_count: 1]
    )
    |> Repo.update_all([])
    |> case do
      {1, [session]} -> {:ok, session}
      {0, _} -> :session_gone
    end
  end

  defp lease_member(member, session, now) do
    Member
    |> where([m], m.id == ^member.id and m.state == "idle")
    |> select([m], m)
    |> update([m],
      set: [
        state: "leased",
        session_id: ^session.id,
        workspace_ready_generation: nil,
        leased_at: ^now,
        updated_at: ^now
      ],
      inc: [lease_generation: 1]
    )
    |> Repo.update_all([])
    |> case do
      {1, [member]} -> {:ok, member}
      {0, _} -> :member_gone
    end
  end
end
