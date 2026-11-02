defmodule GoodFlows.Pools.ReconcilerTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Pools

  alias GoodFlows.Pools.{
    Credentials,
    DestroyMemberJob,
    Member,
    Members,
    Pool,
    ProvisionMemberJob,
    Reconciler,
    ResetMemberJob,
    Session,
    Sessions
  }

  alias GoodFlows.Spry.Executions

  setup :set_mimic_global

  setup do
    test_pid = self()

    stub(PgFlow, :enqueue, fn job, %{"member_id" => id} ->
      send(test_pid, {:enqueued, job, id})
      {:ok, Ecto.UUID.generate()}
    end)

    user = user_fixture()

    {:ok, account} =
      GoodFlows.Accounts.create_account(user, %{
        name: "Acct #{System.unique_integer([:positive])}"
      })

    {key, _token} =
      api_key_fixture(GoodFlows.Accounts.get_account_user(user, account), %{type: :private})

    credential_fixture(account)
    project = project_fixture(account)
    %{account: account, project: project, key: key}
  end

  defp pool(ctx, attrs), do: pool_fixture(ctx.project, attrs)
  defp members(pool), do: Repo.all(Ecto.Query.where(Member, pool_id: ^pool.id))
  defp count(pool, state), do: pool |> members() |> Enum.count(&(&1.state == state))

  defp enqueued(job) do
    receive do
      {:enqueued, ^job, id} -> [id | enqueued(job)]
    after
      0 -> []
    end
  end

  test "keeps min_ready warm", ctx do
    pool = pool(ctx, %{"min_ready" => 2, "max_members" => 4})
    member_fixture(pool)

    Reconciler.reconcile()
    assert count(pool, "provisioning") == 1
    assert length(enqueued(ProvisionMemberJob)) == 1

    # Provisioning members count toward min_ready: no overshoot on the next tick.
    Reconciler.reconcile()
    assert count(pool, "provisioning") == 1
  end

  test "grows for unmet demand up to max_members", ctx do
    pool = pool(ctx, %{"min_ready" => 1, "max_members" => 3})
    member_fixture(pool)
    session = session_fixture(pool, ctx.key, %{owner_id: nil, max_members: 3, wanted: 3})
    # Keep the session alive through the expiry pass.
    stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)

    Reconciler.reconcile()

    assert Repo.reload!(session).granted_count == 1
    # min_ready 1 + 2 unmet, capped at 3 total with the leased one.
    assert count(pool, "provisioning") == 2
    assert length(members(pool)) == 3
  end

  test "shrinks by destroying idle members first and released leased ones later", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 4})
    stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)

    session =
      session_fixture(pool, ctx.key, %{
        status: "active",
        granted_count: 3,
        wanted: 3,
        max_members: 3
      })

    leased = for _ <- 1..3, do: member_fixture(pool, %{state: "leased", session_id: session.id})
    idle = member_fixture(pool)

    {:ok, _} =
      Pools.replace_pool(Repo.get!(Account, pool.account_id), ctx.project, pool.slug, %{
        "slug" => pool.slug,
        "setup" => pool.setup,
        "max_members" => 2,
        "min_ready" => 0
      })

    Reconciler.reconcile()
    assert Repo.reload!(idle).state == "destroying"
    assert Enum.all?(leased, &(Repo.reload!(&1).state == "leased"))

    Repo.delete!(Repo.reload!(idle))
    [first, second, third] = leased
    assert [%{state: "destroying"}] = Members.release(session.id, [first.id])
    assert [%{state: "resetting"}] = Members.release(session.id, [second.id])
    assert [%{state: "resetting"}] = Members.release(session.id, [third.id])
  end

  test "a setup edit retires stale idle members and replaces them; leased ones on release", ctx do
    pool = pool(ctx, %{"min_ready" => 1, "max_members" => 3, "setup" => ["a"]})
    stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)
    idle = member_fixture(pool)
    session = session_fixture(pool, ctx.key, %{status: "active", granted_count: 1, wanted: 1})
    leased = member_fixture(pool, %{state: "leased", session_id: session.id})
    provisioning = member_fixture(pool, %{state: "provisioning", helper_version: nil})

    {:ok, pool} =
      Pools.replace_pool(Repo.get!(Account, pool.account_id), ctx.project, pool.slug, %{
        "slug" => pool.slug,
        "setup" => ["b"],
        "max_members" => 3,
        "min_ready" => 1
      })

    assert pool.setup_version == 2
    Reconciler.reconcile()

    assert Repo.reload!(idle).state == "destroying"
    assert Repo.reload!(leased).state == "leased"
    assert Repo.reload!(provisioning).state == "provisioning"

    # Destroying rows still count toward max_members; once the stale idle
    # member is gone, a current-version replacement is provisioned (the
    # old-version provisioning member does not satisfy min_ready).
    Repo.delete!(Repo.reload!(idle))
    Reconciler.reconcile()

    assert Enum.count(
             members(Repo.get!(Pool, pool.id)),
             &(&1.state == "provisioning" and &1.setup_version == 2)
           ) == 1

    assert [%{state: "destroying"}] = Members.release(session.id, [leased.id])
  end

  test "a new helper artifact retires idle members and leased ones on release", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 3})
    stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)
    idle = member_fixture(pool, %{helper_version: "0.0.1+p1+old"})
    session = session_fixture(pool, ctx.key, %{status: "active", granted_count: 1, wanted: 1})

    leased =
      member_fixture(pool, %{
        state: "leased",
        session_id: session.id,
        helper_version: "0.0.1+p1+old"
      })

    Reconciler.reconcile()
    assert Repo.reload!(idle).state == "destroying"
    assert Repo.reload!(leased).state == "leased"
    assert [%{state: "destroying"}] = Members.release(session.id, [leased.id])
  end

  test "broken members are destroyed and replacement waits for the pool's backoff", ctx do
    pool = pool(ctx, %{"min_ready" => 1, "max_members" => 2})
    broken = member_fixture(pool, %{state: "broken", last_error: "setup[0] exited with code 1"})

    Repo.update!(
      Ecto.Changeset.change(pool,
        provision_failures: 2,
        next_provision_at: DateTime.add(DateTime.utc_now(), 600, :second)
      )
    )

    Reconciler.reconcile()
    assert Repo.reload!(broken).state == "destroying"
    assert [_] = enqueued(DestroyMemberJob)
    assert count(pool, "provisioning") == 0

    # The streak survives the member's removal.
    Repo.delete!(Repo.reload!(broken))
    Reconciler.reconcile()
    assert %{provision_failures: 2} = Repo.reload!(pool)
    assert count(pool, "provisioning") == 0

    Repo.update!(
      Ecto.Changeset.change(Repo.reload!(pool),
        next_provision_at: DateTime.add(DateTime.utc_now(), -1, :second)
      )
    )

    Reconciler.reconcile()
    assert count(pool, "provisioning") == 1
  end

  test "without a credential, provisioning pauses but reset and destroy continue", ctx do
    pool = pool(ctx, %{"min_ready" => 2, "max_members" => 3})
    broken = member_fixture(pool, %{state: "broken"})
    GoodFlows.Spry.delete_credential(ctx.account)

    Reconciler.reconcile()
    assert count(pool, "provisioning") == 0
    assert Repo.reload!(broken).state == "destroying"

    assert {:ok, %{status: "credential_missing"}} =
             Pools.get_pool(ctx.account, ctx.project, pool.slug)

    credential_fixture(ctx.account)
    Reconciler.reconcile()
    assert count(pool, "provisioning") == 2
  end

  test "credential rotation: old sessions keep old members, new ones get new members", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 4})
    stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)

    old_session = session_fixture(pool, ctx.key, %{wanted: 2, max_members: 2})
    old_member = member_fixture(pool)
    spare_old = member_fixture(pool)

    GoodFlows.Spry.put_credential(ctx.account, %{"token" => "rotated_token_5678"})
    new_fp = Credentials.fingerprint("rotated_token_5678")

    new_session =
      session_fixture(pool, ctx.key, %{wanted: 1, max_members: 1, token: "rotated_token_5678"})

    Reconciler.reconcile()

    # The old session is served from its own namespace...
    assert Repo.reload!(old_member).session_id == old_session.id
    assert Repo.reload!(spare_old).session_id == old_session.id
    # ...and the new session's demand provisions in the new namespace.
    new_members = pool |> members() |> Enum.filter(&(&1.credential_fingerprint == new_fp))
    assert [%{state: "provisioning"}] = new_members
    refute Repo.reload!(new_session).first_granted_at

    # Once no old-namespace session needs them, released old members are
    # destroyed (with their own snapshot) rather than reset.
    Sessions.end_session(old_session.id, "released", nil)
    assert Repo.reload!(old_member).state == "destroying"
    assert Repo.reload!(old_member).credential_snapshot == token()

    # And an old-namespace idle member nobody needs is retired.
    idle_old = member_fixture(pool)
    Reconciler.reconcile()
    assert Repo.reload!(idle_old).state == "destroying"
  end

  test "a deleted pool's members are destroyed, then its row is removed", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 3, "slug" => "gone"})
    a = member_fixture(pool)
    b = member_fixture(pool, %{state: "broken"})
    :ok = Pools.delete_pool(ctx.account, ctx.project, "gone")

    Reconciler.reconcile()
    assert Repo.reload!(a).state == "destroying"
    assert Repo.reload!(b).state == "destroying"
    assert Repo.get(Pool, pool.id)

    Repo.delete_all(Ecto.Query.where(Member, pool_id: ^pool.id))
    Reconciler.reconcile()
    refute Repo.get(Pool, pool.id)
  end

  test "deleting a pool races session creation safely", ctx do
    pool = pool(ctx, %{"slug" => "racy"})
    user = user_fixture()
    {:ok, au} = GoodFlows.Accounts.create_account_user(ctx.account, user, %{role: :member})
    {key, _} = api_key_fixture(au, %{type: :private})

    results =
      [
        Task.async(fn -> Pools.delete_pool(ctx.account, ctx.project, "racy") end),
        Task.async(fn ->
          Sessions.create(ctx.account, ctx.project, "racy", key, %{
            "max_members" => 1,
            "acquire_timeout_ms" => 60_000
          })
        end)
      ]
      |> Enum.map(&Task.await/1)

    sessions = Repo.all(Ecto.Query.where(Session, pool_id: ^pool.id))
    deleted? = Repo.reload!(pool).deleting_at != nil

    # Either the deletion won (no session was created) or the session won
    # (the deletion was refused); never both.
    assert deleted? != (sessions != [])
    assert length(results) == 2
  end

  test "workers lost past their deadline are recovered; orphaned jobs are re-enqueued", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 4})
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    stuck =
      member_fixture(pool, %{state: "resetting", owner_id: "x@y|b|u", operation_deadline_at: past})

    gone =
      member_fixture(pool, %{
        state: "provisioning",
        owner_id: Executions.new_owner_id(),
        operation_deadline_at: DateTime.add(past, 3600, :second)
      })

    orphan = member_fixture(pool, %{state: "resetting"})

    Repo.update_all(Ecto.Query.where(Member, id: ^orphan.id),
      set: [updated_at: DateTime.add(past, -600, :second)]
    )

    Reconciler.reconcile()
    assert Repo.reload!(stuck).state in ["broken", "destroying"]
    # Not registered on this node: confirmed lost.
    assert Repo.reload!(gone).state in ["broken", "destroying"]
    assert orphan.id in enqueued(ResetMemberJob)

    # A lost provision counts toward the pool's failure streak and backoff.
    pool = Repo.reload!(pool)
    assert pool.provision_failures == 1
    assert pool.next_provision_at
    assert pool.last_provision_error =~ "provisioning worker was lost"
  end

  test "job-owned members and running execs without a deadline do not crash the tick", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 2})
    owner = Executions.new_owner_id()
    member = member_fixture(pool, %{state: "resetting", owner_id: owner})
    # Its owner is not registered on this node: confirmed lost.
    assert %{} = Reconciler.reconcile()
    assert Repo.reload!(member).state in ["broken", "destroying"]
  end

  test "a tick provisions nothing while pools are disabled", ctx do
    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
    pool = pool(ctx, %{"min_ready" => 2})
    Application.put_env(:good_flows, GoodFlows.Pools, Keyword.put(original, :enabled, false))

    assert %{enabled: false} = Reconciler.reconcile()
    assert members(pool) == []
  end

  test "the scheduler acts only as the cluster leader" do
    name = {:global, {__MODULE__, make_ref()}}

    {:ok, pid} =
      start_supervised(
        {Reconciler, name: :test_reconciler, leader_name: name, interval_ms: 60_000}
      )

    stub(Reconciler, :reconcile, fn _now, _opts -> :ok end)
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert :global.whereis_name(name) == pid
  end

  test "a leader with pools disabled frees the leader name after its pass" do
    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
    Application.put_env(:good_flows, GoodFlows.Pools, Keyword.put(original, :enabled, false))
    name = {:global, {__MODULE__, make_ref()}}

    {:ok, pid} =
      start_supervised(
        {Reconciler, name: :disabled_reconciler, leader_name: name, interval_ms: 60_000}
      )

    test_pid = self()

    stub(Reconciler, :reconcile, fn _now, _opts ->
      send(test_pid, {:reconciled, :global.whereis_name(name)})
      :ok
    end)

    send(pid, :tick)
    _ = :sys.get_state(pid)
    # It ran one wind-down pass as leader, then released the name so an
    # enabled node can take over.
    assert_received {:reconciled, ^pid}
    assert :global.whereis_name(name) == :undefined
  end

  test "the tick winds expired sessions down off the reconciler", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 2})
    test_pid = self()

    session =
      session_fixture(pool, ctx.key, %{
        status: "active",
        granted_count: 1,
        wanted: 1,
        last_seen_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
        owner_id: Executions.new_owner_id()
      })

    member = member_fixture(pool, %{state: "leased", session_id: session.id})
    stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)

    stub(GoodFlows.Pools.OwnerRPC, :call, fn _owner, {:end_session, _, _}, _timeout ->
      send(test_pid, {:winding_down, self()})
      receive do: (:go -> :ok)
      :ok
    end)

    assert %{expired: 1} = Reconciler.reconcile(DateTime.utc_now(), wind_down: :async)
    assert Repo.reload!(session).status == "expired"
    assert_receive {:winding_down, task}
    assert Repo.reload!(member).state == "leased"

    ref = Process.monitor(task)
    send(task, :go)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert Repo.reload!(member).state == "resetting"
  end

  test "a reconciler that is not the leader does nothing" do
    name = {:global, {__MODULE__, make_ref()}}
    holder = spawn(fn -> Process.sleep(:infinity) end)
    :yes = :global.register_name(name, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)

    {:ok, pid} =
      start_supervised(
        {Reconciler, name: :follower_reconciler, leader_name: name, interval_ms: 60_000}
      )

    reject(Reconciler, :reconcile, 0)
    send(pid, :tick)
    send(pid, {:pools_nudge, nil})
    send(pid, :nudged)
    _ = :sys.get_state(pid)
    assert :global.whereis_name(name) == holder
  end

  describe "fault isolation" do
    test "a pool whose pass raises does not stop the other pools", ctx do
      bad = pool(ctx, %{"slug" => "bad", "min_ready" => 1, "max_members" => 2})
      bad_member = member_fixture(bad)
      good = pool(ctx, %{"slug" => "good", "min_ready" => 1, "max_members" => 2})
      bad_id = bad_member.id

      stub(Pools, :stale?, fn
        %Member{id: ^bad_id}, _pool -> raise "boom"
        member, pool -> call_original(Pools, :stale?, [member, pool])
      end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert %{} = Reconciler.reconcile() end)
      assert log =~ "boom"
      assert count(good, "provisioning") == 1
    end

    test "a member name collision skips the admission instead of crashing", ctx do
      existing = member_fixture(pool(ctx, %{"slug" => "other", "min_ready" => 0}))
      pool = pool(ctx, %{"min_ready" => 2, "max_members" => 3})
      Application.put_env(:good_flows, :pool_member_name_generator, fn -> existing.name end)
      on_exit(fn -> Application.delete_env(:good_flows, :pool_member_name_generator) end)

      assert %{} = Reconciler.reconcile()
      assert count(pool, "provisioning") == 0
    end
  end

  test "the provisioning backoff is checked on the locked pool row", ctx do
    pool = pool(ctx, %{"min_ready" => 2, "max_members" => 3})
    idle = member_fixture(pool)
    idle_id = idle.id
    future = DateTime.add(DateTime.utc_now(), 600, :second)

    # A concurrent failure records a backoff after this pass read the pools.
    stub(Pools, :stale?, fn
      %Member{id: ^idle_id} = member, p ->
        Repo.update_all(Ecto.Query.where(Pool, id: ^pool.id), set: [next_provision_at: future])
        call_original(Pools, :stale?, [member, p])

      member, p ->
        call_original(Pools, :stale?, [member, p])
    end)

    Reconciler.reconcile()
    assert count(pool, "provisioning") == 0
  end

  test "a missing credential never retires warm members of the last namespace", ctx do
    pool = pool(ctx, %{"min_ready" => 1, "max_members" => 2})
    idle = member_fixture(pool)
    GoodFlows.Spry.delete_credential(ctx.account)

    Reconciler.reconcile()
    assert Repo.reload!(idle).state == "idle"
  end

  test "an orphan with a pending job is not re-enqueued again", ctx do
    pool = pool(ctx, %{"min_ready" => 0, "max_members" => 2})
    orphan = member_fixture(pool, %{state: "resetting"})
    old = DateTime.add(DateTime.utc_now(), -600, :second)
    Repo.update_all(Ecto.Query.where(Member, id: ^orphan.id), set: [updated_at: old])
    orphan_id = orphan.id

    stub(PgFlow.Runs, :count, fn _repo, opts ->
      assert opts[:flow_slug] == "pool_member_reset"
      assert opts[:input_contains] == %{"member_id" => orphan_id}
      {:ok, 1}
    end)

    Reconciler.reconcile()
    refute orphan.id in enqueued(ResetMemberJob)
  end

  describe "members that can never be destroyed" do
    test "a deleted pool finishes even when only abandoned members remain", ctx do
      pool = pool(ctx, %{"min_ready" => 0, "max_members" => 3, "slug" => "doomed"})
      abandoned = member_fixture(pool, %{state: "abandoned", last_error: "destroy failed: 401"})
      :ok = Pools.delete_pool(ctx.account, ctx.project, "doomed")

      log = ExUnit.CaptureLog.capture_log(fn -> Reconciler.reconcile() end)
      refute Repo.get(Pool, pool.id)
      refute Repo.reload(abandoned)
      assert log =~ abandoned.name
      assert log =~ "abandoned"
    end
  end

  describe "while pools are disabled" do
    setup do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
      %{original: original}
    end

    defp disable(ctx),
      do:
        Application.put_env(
          :good_flows,
          GoodFlows.Pools,
          Keyword.put(ctx.original, :enabled, false)
        )

    test "sessions still expire and deleted pools are still cleaned up", ctx do
      live = pool(ctx, %{"min_ready" => 2, "slug" => "live"})

      session =
        session_fixture(live, ctx.key, %{
          last_seen_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
          owner_id: Executions.new_owner_id()
        })

      doomed = pool(ctx, %{"min_ready" => 1, "slug" => "rollback"})
      idle = member_fixture(doomed)
      broken = member_fixture(live, %{state: "broken"})
      :ok = Pools.delete_pool(ctx.account, ctx.project, "rollback")
      disable(ctx)

      assert %{} = Reconciler.reconcile()
      assert Repo.reload!(session).status == "expired"
      # Nothing new is provisioned, but the deleted pool's members and
      # broken members go.
      assert count(live, "provisioning") == 0
      assert Repo.reload!(idle).state == "destroying"
      assert Repo.reload!(broken).state == "destroying"
    end

    test "no member is granted or provisioned", ctx do
      pool = pool(ctx, %{"min_ready" => 2, "max_members" => 3})
      idle = member_fixture(pool)
      session_fixture(pool, ctx.key, %{wanted: 1, owner_id: Executions.new_owner_id()})
      stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)
      disable(ctx)

      assert %{} = Reconciler.reconcile()
      assert Repo.reload!(idle).state == "idle"
      assert count(pool, "provisioning") == 0
    end
  end

  describe "idle shrink (idle_ttl_ms)" do
    defp idle_for(member, ms) do
      since = DateTime.add(DateTime.utc_now(), -ms, :millisecond)
      Repo.update_all(Ecto.Query.where(Member, id: ^member.id), set: [idle_since: since])
    end

    test "is off by default: idle members above min_ready stay", ctx do
      pool = pool(ctx, %{"min_ready" => 1, "max_members" => 3})
      members = for _ <- 1..3, do: member_fixture(pool)
      Enum.each(members, &idle_for(&1, 86_400_000))

      Reconciler.reconcile()
      assert count(pool, "idle") == 3
    end

    test "retires members idle past the TTL down to min_ready plus demand", ctx do
      pool = pool(ctx, %{"min_ready" => 1, "max_members" => 4, "idle_ttl_ms" => 60_000})
      [old1, old2, fresh] = for _ <- 1..3, do: member_fixture(pool)
      idle_for(old1, 120_000)
      idle_for(old2, 120_000)
      idle_for(fresh, 1_000)

      session_fixture(pool, ctx.key, %{wanted: 0})

      Reconciler.reconcile()
      # min_ready 1 and no demand: both members past the TTL are retired;
      # the fresh one stays as the warm member.
      assert Repo.reload!(old1).state == "destroying"
      assert Repo.reload!(old2).state == "destroying"
      assert Repo.reload!(fresh).state == "idle"
    end

    test "keeps enough idle members for min_ready plus unmet demand", ctx do
      pool = pool(ctx, %{"min_ready" => 1, "max_members" => 4, "idle_ttl_ms" => 60_000})
      members = for _ <- 1..3, do: member_fixture(pool)
      Enum.each(members, &idle_for(&1, 120_000))
      # A session in another namespace wants 1 more (so nothing is granted
      # to it here), which still counts as demand.
      session_fixture(pool, ctx.key, %{wanted: 1, token: "other_token_0000"})
      stub(GoodFlows.Pools.OwnerRPC, :status, fn _ -> :alive end)

      Reconciler.reconcile()
      assert count(pool, "idle") == 2
    end
  end

  test "ended sessions past the retention period are deleted with their execs", ctx do
    pool = pool(ctx, %{"min_ready" => 0})
    member = member_fixture(pool)
    long_ago = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)

    old =
      session_fixture(pool, ctx.key, %{status: "released", ended_at: long_ago, wanted: 0})

    recent =
      session_fixture(pool, ctx.key, %{status: "released", ended_at: DateTime.utc_now()})

    exec = exec_fixture(old, member, %{status: "exited"})

    Reconciler.reconcile()
    refute Repo.reload(old)
    refute Repo.reload(exec)
    assert Repo.reload(recent)
  end
end
