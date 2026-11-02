defmodule GoodFlows.Pools.GrantsTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Pools.{Events, Grants, Member, Session, Sessions}

  setup :set_mimic_global

  setup do
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    account = account_fixture()
    credential_fixture(account)
    pool = account |> project_fixture() |> pool_fixture(%{"max_members" => 8})
    %{pool: pool}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  test "a session gets the one idle member and becomes active", ctx do
    session = session_fixture(ctx.pool, nil, %{max_members: 4, wanted: 4})
    member = member_fixture(ctx.pool)
    Events.subscribe(Events.session_topic(session.id))

    assert [{session_id, %Member{id: member_id}}] = Grants.grant(ctx.pool.id)
    assert session_id == session.id
    assert member_id == member.id

    session = Repo.reload!(session)
    assert session.status == "active"
    assert session.granted_count == 1
    assert session.first_granted_at

    member = Repo.reload!(member)
    assert member.state == "leased"
    assert member.session_id == session.id
    refute Member.ready?(member)

    assert_receive {:pool_session_event, "member_granted", %{member_id: ^member_id, name: _}}
  end

  test "a session holding nothing is served before a holding session", ctx do
    a =
      session_fixture(ctx.pool, nil, %{
        status: "active",
        granted_count: 2,
        wanted: 4,
        wanting_since: ago(600)
      })

    b = session_fixture(ctx.pool, nil, %{granted_count: 0, wanted: 4, wanting_since: ago(1)})
    member_fixture(ctx.pool)

    assert [{session_id, _}] = Grants.grant(ctx.pool.id)
    assert session_id == b.id
    assert Repo.reload!(a).granted_count == 2
  end

  test "priority is recomputed after each grant in a batch", ctx do
    a = session_fixture(ctx.pool, nil, %{wanted: 3, wanting_since: ago(30)})
    b = session_fixture(ctx.pool, nil, %{wanted: 3, wanting_since: ago(20)})
    for _ <- 1..4, do: member_fixture(ctx.pool)

    order = ctx.pool.id |> Grants.grant() |> Enum.map(&elem(&1, 0))
    # Zero-holding sessions first (a, then b), then by time since last grant.
    assert order == [a.id, b.id, a.id, b.id]
  end

  test "grants stop at wanted and skip stale and other-namespace members", ctx do
    session = session_fixture(ctx.pool, nil, %{wanted: 1, max_members: 4})
    member_fixture(ctx.pool, %{helper_version: "old"})
    member_fixture(ctx.pool, %{setup_version: 0})
    member_fixture(ctx.pool, %{token: "another_token_9999"})
    assert Grants.grant(ctx.pool.id) == []

    good = member_fixture(ctx.pool)
    member_fixture(ctx.pool)
    assert [{_, %{id: id}}] = Grants.grant(ctx.pool.id)
    assert id == good.id
    assert Repo.reload!(session).granted_count == 1
  end

  test "concurrent grants never assign a member twice", ctx do
    for _ <- 1..6, do: session_fixture(ctx.pool, nil, %{wanted: 2})
    for _ <- 1..5, do: member_fixture(ctx.pool)

    granted =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Grants.grant(ctx.pool.id) end) end)
      |> Enum.flat_map(&Task.await/1)

    ids = Enum.map(granted, fn {_s, m} -> m.id end)
    assert length(ids) == 5
    assert ids == Enum.uniq(ids)

    leased = Repo.all(Ecto.Query.where(Member, state: "leased"))
    assert length(leased) == 5

    total = Session |> Repo.all() |> Enum.map(& &1.granted_count) |> Enum.sum()
    assert total == 5
  end

  test "lowering wanted never revokes; releasing the last member is not replaced", ctx do
    session = session_fixture(ctx.pool, nil, %{max_members: 3, wanted: 3})
    [m1, _m2] = for _ <- 1..2, do: member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    session = Repo.reload!(session)
    assert session.granted_count == 2

    assert Sessions.set_wanted(session, 0) == :ok
    assert length(Sessions.members(session.id)) == 2

    assert Sessions.set_wanted(session, 4) == {:error, :invalid}
    assert Sessions.set_wanted(session, -1) == {:error, :invalid}

    [first | _] = Sessions.members(session.id)
    assert Sessions.release_member(Repo.reload!(session), first.id) == :ok
    session = Repo.reload!(session)
    assert session.granted_count == 1
    assert session.wanted == 0

    # Another idle member is not granted to it.
    member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    assert Repo.reload!(session).granted_count == 1

    assert Repo.reload!(first).state in ["resetting", "destroying"]
    assert Sessions.release_member(session, m1.id) in [:ok, {:error, :not_granted}]
  end

  test "release_member leaves wanted at most the remaining holdings, then want raises it", ctx do
    session = session_fixture(ctx.pool, nil, %{max_members: 2, wanted: 2})
    member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    [held] = Sessions.members(session.id)

    :ok = Sessions.release_member(Repo.reload!(session), held.id)
    session = Repo.reload!(session)
    assert {session.granted_count, session.wanted} == {0, 0}
    # first_granted_at stays: no acquisition expiry later.
    assert session.first_granted_at

    :ok = Sessions.set_wanted(session, 1)
    member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    assert Repo.reload!(session).granted_count == 1
  end

  describe "races between reading candidates and leasing" do
    # The sandbox shares one connection, so concurrent writers cannot
    # interleave inside the grant transaction. `Pools.grantable?/2` runs after
    # the candidates are read and before any lease, so a stub there injects
    # the concurrent write deterministically.
    defp once_before_lease(fun) do
      flag = :counters.new(1, [])

      stub(GoodFlows.Pools, :grantable?, fn member, pool ->
        if :counters.get(flag, 1) == 0 do
          :counters.add(flag, 1, 1)
          fun.()
        end

        call_original(GoodFlows.Pools, :grantable?, [member, pool])
      end)
    end

    test "a session that ended meanwhile is not reopened and leases nothing", ctx do
      session = session_fixture(ctx.pool, nil, %{wanted: 1})
      member = member_fixture(ctx.pool)

      once_before_lease(fn ->
        Repo.update_all(where(Session, id: ^session.id),
          set: [status: "released", ended_at: DateTime.utc_now()]
        )
      end)

      assert Grants.grant(ctx.pool.id) == []
      assert Repo.reload!(session).status == "released"
      assert Repo.reload!(member).state == "idle"
    end

    test "a member taken meanwhile is skipped instead of crashing the grant", ctx do
      session = session_fixture(ctx.pool, nil, %{wanted: 2})
      taken = member_fixture(ctx.pool)
      other = member_fixture(ctx.pool)

      once_before_lease(fn ->
        Repo.update_all(where(Member, id: ^taken.id), set: [state: "destroying"])
      end)

      assert [{session_id, %Member{id: member_id}}] = Grants.grant(ctx.pool.id)
      assert {session_id, member_id} == {session.id, other.id}
      assert Repo.reload!(taken).state == "destroying"
      assert Repo.reload!(session).granted_count == 1
    end

    test "a concurrent holdings decrement is not overwritten", ctx do
      session =
        session_fixture(ctx.pool, nil, %{status: "active", granted_count: 2, wanted: 3})

      member_fixture(ctx.pool)

      once_before_lease(fn ->
        Repo.update_all(where(Session, id: ^session.id), inc: [granted_count: -1])
      end)

      assert [_] = Grants.grant(ctx.pool.id)
      assert Repo.reload!(session).granted_count == 2
    end
  end

  test "a session past its acquisition deadline without a grant is not granted", ctx do
    late =
      session_fixture(ctx.pool, nil, %{
        wanted: 1,
        acquire_deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    member_fixture(ctx.pool)
    assert Grants.grant(ctx.pool.id) == []
    assert Repo.reload!(late).status == "waiting"
  end

  test "release_member computes holdings from the leased members", ctx do
    session = session_fixture(ctx.pool, nil, %{max_members: 4, wanted: 4})
    for _ <- 1..2, do: member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    # A drifted counter (as a lost update would leave it).
    Repo.update_all(where(Session, id: ^session.id), set: [granted_count: 5])

    [first | _] = Sessions.members(session.id)
    :ok = Sessions.release_member(Repo.reload!(session), first.id)
    session = Repo.reload!(session)
    assert {session.granted_count, session.wanted} == {1, 1}
  end

  test "nothing is granted from a pool being deleted", ctx do
    session_fixture(ctx.pool, nil)
    member_fixture(ctx.pool)
    Repo.update!(Ecto.Changeset.change(ctx.pool, deleting_at: DateTime.utc_now()))
    assert Grants.grant(ctx.pool.id) == []
  end
end
