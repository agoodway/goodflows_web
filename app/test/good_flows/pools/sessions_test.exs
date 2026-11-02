defmodule GoodFlows.Pools.SessionsTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts

  alias GoodFlows.Pools.{
    Config,
    Events,
    Exec,
    Execs,
    Grants,
    Member,
    OwnerRPC,
    Session,
    SessionCoordinator,
    Sessions,
    Spool
  }

  alias GoodFlows.Spry.Executions
  alias GoodFlows.Spry.Sprites, as: Wrapper

  setup :set_mimic_global

  setup do
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    account_user = Accounts.get_account_user(user, account)
    {key, _token} = api_key_fixture(account_user, %{type: :private})
    {other_key, _} = api_key_fixture(account_user, %{type: :private})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "rust-ci", "max_members" => 4})
    %{account: account, project: project, pool: pool, key: key, other_key: other_key}
  end

  defp create(ctx, attrs \\ %{"max_members" => 2, "acquire_timeout_ms" => 60_000}),
    do: Sessions.create(ctx.account, ctx.project, "rust-ci", ctx.key, attrs)

  defp coordinator(session) do
    {:ok, pid} = Executions.lookup(session.owner_id)
    pid
  end

  describe "create/5" do
    test "starts a waiting session owned by a local coordinator and records the key", ctx do
      assert {:ok, session} =
               create(ctx, %{"max_members" => 4, "acquire_timeout_ms" => 120_000, "label" => "ci"})

      assert session.status == "waiting"
      assert session.wanted == 4
      assert session.api_key_id == ctx.key.id
      assert session.pool_slug == "rust-ci"
      assert session.project_slug == "app"
      assert Executions.local_owner?(session.owner_id)
      assert is_pid(coordinator(session))
      assert OwnerRPC.call(session.owner_id, :ping) == :pong
    end

    test "never stores or logs the credential", ctx do
      log =
        capture_log([level: :debug], fn ->
          Logger.configure(level: :debug)

          try do
            {:ok, session} = create(ctx)
            send(self(), {:session, session})
          after
            Logger.configure(level: :warning)
          end
        end)

      assert_received {:session, session}
      refute log =~ token()

      %{rows: [row]} =
        Repo.query!("SELECT * FROM pool_sessions WHERE id = $1", [Ecto.UUID.dump!(session.id)])

      refute inspect(row) =~ token()
      refute inspect(session) =~ token()

      # The coordinator's crash-report state drops the client.
      status = :sys.get_status(coordinator(session))
      refute inspect(status) =~ token()
    end

    test "422 for invalid bodies, unknown keys, and a missing credential", ctx do
      assert {:error, cs} = create(ctx, %{"max_members" => 5, "acquire_timeout_ms" => 60_000})
      assert errors_on(cs)[:max_members]

      assert {:error, cs} = create(ctx, %{"max_members" => 2, "acquire_timeout_ms" => 999})
      assert errors_on(cs)[:acquire_timeout_ms]

      assert {:error, cs} =
               create(ctx, %{"max_members" => 2, "acquire_timeout_ms" => 60_000, "priority" => 9})

      assert errors_on(cs)["priority"]

      assert {:error, cs} =
               create(ctx, %{
                 "max_members" => 2,
                 "acquire_timeout_ms" => 60_000,
                 "label" => "a\u0007"
               })

      assert errors_on(cs)[:label]

      GoodFlows.Spry.delete_credential(ctx.account)
      assert {:error, {:unprocessable, message}} = create(ctx)
      assert message =~ "Sprites credential must be configured"
      assert Repo.aggregate(Session, :count) == 0
    end

    test "404 for an unknown or deleted pool", ctx do
      assert Sessions.create(ctx.account, ctx.project, "nope", ctx.key, %{}) ==
               {:error, :not_found}

      :ok = GoodFlows.Pools.delete_pool(ctx.account, ctx.project, "rust-ci")
      assert create(ctx) == {:error, :not_found}
    end

    test "only the creating key owns the session", ctx do
      {:ok, session} = create(ctx)
      assert {:ok, _} = Sessions.get_owned(ctx.account, ctx.key, session.id)
      assert Sessions.get_owned(ctx.account, ctx.other_key, session.id) == {:error, :forbidden}
      assert Sessions.get_owned(account_fixture(), ctx.key, session.id) == {:error, :not_found}
    end
  end

  describe "ending" do
    test "release is idempotent, resets members, stops the coordinator, and broadcasts", ctx do
      member_fixture(ctx.pool)
      {:ok, session} = create(ctx)
      [member] = Sessions.members(session.id)
      ref = Process.monitor(coordinator(session))
      Events.subscribe(Events.session_topic(session.id))

      assert Sessions.release(session) == :ok
      assert_receive {:pool_session_event, "session_ended", %{status: "released", reason: nil}}
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert Repo.reload!(member).state == "resetting"

      assert %Session{status: "released", end_reason: nil, ended_at: %DateTime{}} =
               Repo.reload!(session)

      assert Sessions.release(session) == :ok
      assert Sessions.end_session(session.id, "expired", "client_disconnected") == :already_ended
    end

    test "a running exec ends cancelled and its exit precedes session_ended", ctx do
      member_fixture(ctx.pool)
      {:ok, session} = create(ctx)
      [member] = Sessions.members(session.id)

      Repo.update_all(Ecto.Query.where(Member, id: ^member.id),
        set: [workspace_ready_generation: member.lease_generation]
      )

      stub(Wrapper, :spawn_streaming, fn _c, _n, _cmd, _args, _owner, _opts ->
        {:ok, %{ref: make_ref(), pid: spawn(fn -> Process.sleep(:infinity) end)}}
      end)

      stub(Wrapper, :stop_stream, fn %{pid: pid} -> Process.exit(pid, :kill) end)

      stub(Wrapper, :exec, fn _c, _n, _line, _opts ->
        {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end)

      stub(Wrapper, :collect, fn _c, _n, _argv, _opts ->
        {:error, %{status: nil, message: "x"}}
      end)

      {:ok, request} =
        Execs.validate_request(%{
          "member_id" => member.id,
          "command" => "sleep 100"
        })

      assert {:ok, exec_id} = OwnerRPC.call(session.owner_id, {:start_exec, request})

      Events.subscribe(Events.exec_topic(exec_id))
      Events.subscribe(Events.session_topic(session.id))
      :ok = Sessions.release(session)

      assert_receive {:pool_exec_event, "exit", %{status: "cancelled", exec_id: ^exec_id}}
      assert_receive {:pool_session_event, "session_ended", _}
      assert %Exec{status: "cancelled"} = Repo.get!(Exec, exec_id)
    end

    test "owner loss ends running execs with error/owner_lost", ctx do
      member_fixture(ctx.pool)
      {:ok, session} = create(ctx)
      [member] = Sessions.members(session.id)
      exec = exec_fixture(session, member)

      # The coordinator dies without cleaning up.
      pid = coordinator(session)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}

      assert [{_, "session_owner_lost"}] = Sessions.expire_due()
      assert %Exec{status: "error", error_reason: "owner_lost"} = Repo.reload!(exec)
      # Confirmed lost: the member is released for reset.
      assert Repo.reload!(member).state == "resetting"
    end
  end

  describe "expire_due/1" do
    setup ctx do
      {:ok, session} = create(ctx)
      %{session: session}
    end

    defp set(session, fields),
      do: Repo.update_all(Ecto.Query.where(Session, id: ^session.id), set: fields)

    defp ago(ms), do: DateTime.add(DateTime.utc_now(), -ms, :millisecond)

    test "nothing is due for a fresh session", %{session: session} do
      assert Sessions.expire_due() == []
      assert Repo.reload!(session).status == "waiting"
    end

    test "no member by the acquisition deadline", %{session: session} do
      set(session, acquire_deadline_at: ago(1))
      assert Sessions.expire_due() == [{session.id, "no_member_available"}]
      assert %{status: "expired", end_reason: "no_member_available"} = Repo.reload!(session)
    end

    test "a session that has had a member never expires by acquisition", %{session: session} do
      set(session, acquire_deadline_at: ago(1), first_granted_at: ago(10), status: "active")
      assert Sessions.expire_due() == []
    end

    test "disconnected beyond the grace", %{session: session} do
      set(session, last_seen_at: ago(Config.disconnect_grace_ms() + 1_000))
      assert Sessions.expire_due() == [{session.id, "client_disconnected"}]
    end

    test "an expired session's execs are cancelled, its members reset, and GET shows it",
         ctx do
      session = ctx.session
      member_fixture(ctx.pool)
      Grants.grant(ctx.pool.id)
      [member] = Sessions.members(session.id)

      Repo.update_all(Ecto.Query.where(Member, id: ^member.id),
        set: [workspace_ready_generation: member.lease_generation]
      )

      GoodFlows.FakeExec.stub!(self())
      {:ok, request} = Execs.validate_request(%{"member_id" => member.id, "command" => "x"})
      {:ok, exec_id} = OwnerRPC.call(session.owner_id, {:start_exec, request})

      set(session, last_seen_at: ago(Config.disconnect_grace_ms() + 1_000))
      assert Sessions.expire_due() == [{session.id, "client_disconnected"}]

      assert %Exec{status: "cancelled"} = Repo.get!(Exec, exec_id)
      assert Repo.reload!(member).state == "resetting"

      assert {:ok, read} = Sessions.get(ctx.account, session.id)
      assert {read.status, read.end_reason} == {"expired", "client_disconnected"}
      assert Sessions.members(read.id) == []
    end

    test "lifetime exceeded", %{session: session} do
      set(session, inserted_at: ago(Config.max_session_lifetime_ms() + 1_000))
      assert Sessions.expire_due() == [{session.id, "lifetime_exceeded"}]
    end

    test "creating key revoked, expired, or deleted", %{session: session} = ctx do
      {:ok, _} = Accounts.revoke_api_key(ctx.key)
      assert Sessions.expire_due() == [{session.id, "key_revoked"}]
    end

    test "creating key deleted nilifies api_key_id and expires", %{session: session} = ctx do
      Repo.delete!(ctx.key)
      assert Repo.reload!(session).api_key_id == nil
      assert Sessions.expire_due() == [{session.id, "key_revoked"}]
    end

    test "heartbeat refreshes last_seen_at and reports a revoked key",
         %{session: session} = ctx do
      set(session, last_seen_at: ago(50_000))
      assert Sessions.heartbeat(session.id) == :ok
      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(session).last_seen_at) < 5

      {:ok, _} = Accounts.revoke_api_key(ctx.key)
      assert Sessions.heartbeat(session.id) == {:ended, "expired", "key_revoked"}
    end
  end

  describe "owner routing" do
    test "calls on another node go through :erpc to that node, which checks the boot", ctx do
      {:ok, session} = create(ctx)
      test_pid = self()
      [_node, boot, uuid] = String.split(session.owner_id, "|")
      remote_owner = "other@host|#{boot}|#{uuid}"
      _ = String.to_atom("other@host")

      Application.put_env(:good_flows, :pools_remote_call, fn node,
                                                              mod,
                                                              fun,
                                                              [owner, req, timeout],
                                                              _t ->
        send(test_pid, {:erpc, node, owner})
        # Simulate the remote node answering for the real local owner.
        apply(mod, fun, [session.owner_id, req, timeout])
      end)

      on_exit(fn -> Application.delete_env(:good_flows, :pools_remote_call) end)

      assert OwnerRPC.call(remote_owner, :ping) == :pong
      assert_received {:erpc, :other@host, ^remote_owner}

      # An unreachable node is unknown, not lost.
      Application.put_env(:good_flows, :pools_remote_call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert OwnerRPC.status(remote_owner) == :unknown

      # A previous boot of this node is a confirmed loss.
      stale = "#{node()}|deadbeef|#{uuid}"
      assert OwnerRPC.status(stale) == :lost
    end

    test "an unreachable owner keeps the session until its lease lapses", ctx do
      {:ok, session} = create(ctx)
      [_node, boot, uuid] = String.split(session.owner_id, "|")
      _ = String.to_atom("gone@host")

      Repo.update_all(Ecto.Query.where(Session, id: ^session.id),
        set: [owner_id: "gone@host|#{boot}|#{uuid}"]
      )

      Application.put_env(:good_flows, :pools_remote_call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      on_exit(fn -> Application.delete_env(:good_flows, :pools_remote_call) end)

      assert Sessions.expire_due() == []

      # The lease (renewed to now + grace) has just run out: no second grace.
      Repo.update_all(Ecto.Query.where(Session, id: ^session.id),
        set: [owner_lease_expires_at: DateTime.add(DateTime.utc_now(), 5, :second)]
      )

      assert Sessions.expire_due() == []

      Repo.update_all(Ecto.Query.where(Session, id: ^session.id),
        set: [owner_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert Sessions.expire_due() == [{session.id, "session_owner_lost"}]
    end
  end

  test "the periodic spool sweep removes spools whose session ended or lost its owner", ctx do
    {:ok, live} = create(ctx)
    {:ok, ended} = create(ctx)
    {:ok, orphaned} = create(ctx)

    Repo.update_all(Ecto.Query.where(Session, id: ^ended.id), set: [status: "released"])
    # A coordinator killed without running terminate/2 leaves its spool behind.
    Process.exit(coordinator(orphaned), :kill)

    unknown = Ecto.UUID.generate()

    dirs =
      for id <- [live.id, ended.id, orphaned.id, unknown],
          do: Spool.session_dir(id)

    Enum.each(dirs, &File.mkdir_p!/1)
    on_exit(fn -> Enum.each(dirs, &File.rm_rf/1) end)

    eventually = fn eventually, n ->
      if Executions.lookup(orphaned.owner_id) == :error or n == 0,
        do: :ok,
        else:
          (
            Process.sleep(10)
            eventually.(eventually, n - 1)
          )
    end

    eventually.(eventually, 100)

    assert Spool.sweep() == 3
    assert Enum.map(dirs, &File.exists?/1) == [true, false, false, false]
  end

  test "the coordinator stops when its lease renewal finds the session ended", ctx do
    {:ok, session} = create(ctx)
    pid = coordinator(session)
    ref = Process.monitor(pid)
    Repo.update_all(Ecto.Query.where(Session, id: ^session.id), set: [status: "expired"])
    send(pid, :renew)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    SessionCoordinator.stop(pid)
  end
end
