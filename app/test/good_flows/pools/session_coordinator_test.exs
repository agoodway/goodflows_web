defmodule GoodFlows.Pools.SessionCoordinatorTest do
  # The coordinator's responsiveness, spool accounting, task supervision,
  # and database-error handling, with stubbed transfers and execs.
  use GoodFlows.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TarFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FakeExec

  alias GoodFlows.Pools.{
    Config,
    Events,
    Execs,
    Member,
    OwnerRPC,
    SessionCoordinator,
    Sessions,
    Spool,
    Transfers
  }

  alias GoodFlows.Spry.Executions
  alias GoodFlows.Spry.Sprites, as: Wrapper

  setup :set_mimic_global

  setup do
    test_pid = self()
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    FakeExec.stub!(test_pid)

    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    {key, _} = api_key_fixture(Accounts.get_account_user(user, account), %{type: :private})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "p", "max_members" => 4})
    [m1, m2] = for _ <- 1..2, do: member_fixture(pool)

    {:ok, session} =
      Sessions.create(account, project, "p", key, %{
        "max_members" => 3,
        "acquire_timeout_ms" => 60_000
      })

    Events.subscribe(Events.session_topic(session.id))
    {:ok, pid} = Executions.lookup(session.owner_id)

    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

    %{
      account: account,
      project: project,
      key: key,
      pool: pool,
      session: Repo.reload!(session),
      owner: session.owner_id,
      pid: pid,
      m1: Repo.reload!(m1),
      m2: Repo.reload!(m2),
      original: original
    }
  end

  defp ready!(member) do
    Repo.update_all(Ecto.Query.where(Member, id: ^member.id),
      set: [workspace_ready_generation: member.lease_generation]
    )
  end

  defp start_exec(ctx, member) do
    {:ok, request} = Execs.validate_request(%{"member_id" => member.id, "command" => "sleep 1"})
    OwnerRPC.call(ctx.owner, {:start_exec, request})
  end

  # The remote kill (a cancel's first step) blocks until the test says go.
  defp block_remote_kill(exit_code \\ 0) do
    test_pid = self()

    stub(Wrapper, :exec, fn _client, _name, _line, _opts ->
      send(test_pid, {:kill_started, self()})
      receive do: (:go -> :ok)
      {:ok, %{exit_code: exit_code, output: "", output_truncated: false}}
    end)
  end

  defp upload!(ctx, bytes) do
    {:ok, ref} = OwnerRPC.call(ctx.owner, {:upload_begin, self()})
    :ok = OwnerRPC.call(ctx.owner, {:upload_chunk, ref, bytes})
    OwnerRPC.call(ctx.owner, {:upload_finish, ref}, 10_000)
  end

  defp archive, do: tar_gz([{:file, "a.txt", "hello"}])

  # Hydrations announce themselves and wait for `:go` (or apply `then`).
  defp stub_hydration(then \\ :wait) do
    test_pid = self()

    stub(Transfers, :receive_workspace, fn _client, member, _sid, _ws, _deadline, _opts ->
      send(test_pid, {:hydrating, member.id, self()})

      case then do
        :wait -> receive do: (:go -> :ok)
        :ok -> :ok
        :die -> Process.exit(self(), :kill)
      end
    end)
  end

  describe "cancels never block the coordinator" do
    test "release_member waits on the exec stop in a task; the coordinator stays responsive",
         ctx do
      ready!(ctx.m1)
      assert {:ok, _exec_id} = start_exec(ctx, ctx.m1)
      assert_receive {:exec_started, _pid, _info}
      block_remote_kill()

      release = Task.async(fn -> Sessions.release_member(ctx.session, ctx.m1.id) end)
      assert_receive {:kill_started, killer}, 2_000

      # Lease renewal and pings are served meanwhile, and the member being
      # released admits no new exec.
      assert OwnerRPC.call(ctx.owner, :ping, 500) == :pong
      assert start_exec(ctx, ctx.m1) == {:error, "not_granted"}

      send(killer, :go)
      assert Task.await(release, 10_000) == :ok
      assert Repo.reload!(ctx.m1).state == "resetting"
      assert %{wanted: 1, granted_count: 1} = Repo.reload!(ctx.session)
    end

    test "ending a session cancels its execs off the coordinator", ctx do
      ready!(ctx.m1)
      assert {:ok, exec_id} = start_exec(ctx, ctx.m1)
      assert_receive {:exec_started, _pid, _info}
      block_remote_kill()
      ref = Process.monitor(ctx.pid)

      ending = Task.async(fn -> Sessions.release(ctx.session) end)
      assert_receive {:kill_started, killer}, 2_000
      assert OwnerRPC.call(ctx.owner, :ping, 500) == :pong
      assert start_exec(ctx, ctx.m2) == {:error, "ended"}

      send(killer, :go)
      assert Task.await(ending, 10_000) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert Repo.get!(GoodFlows.Pools.Exec, exec_id).status == "cancelled"
    end

    test "a release whose exec kill is unconfirmed still releases (no duplicate reset)", ctx do
      ready!(ctx.m1)
      assert {:ok, _exec_id} = start_exec(ctx, ctx.m1)
      assert_receive {:exec_started, _pid, _info}
      # Exit 1: the process group could not be confirmed dead.
      stub(Wrapper, :exec, fn _client, _name, _line, _opts ->
        {:ok, %{exit_code: 1, output: "", output_truncated: false}}
      end)

      assert Sessions.release_member(ctx.session, ctx.m1.id) == :ok
      # Only the release resets the member; the exec server did not report
      # it lost (which would have kept `wanted` and granted a replacement).
      refute_received {:pool_session_event, "member_lost", _}
      assert Repo.reload!(ctx.m1).state == "resetting"
      assert %{wanted: 1, granted_count: 1} = Repo.reload!(ctx.session)
    end
  end

  describe "spool accounting" do
    test "a finished upload keeps only its actual size reserved", ctx do
      stub_hydration(:ok)
      bytes = archive()
      assert upload!(ctx, bytes) == :ok
      assert Spool.reserved_bytes(ctx.account.id) == byte_size(bytes)
    end

    test "a report download reserves the report cap, then its actual size", ctx do
      ready!(ctx.m1)
      member = Repo.reload!(ctx.m1)

      exec =
        exec_fixture(ctx.session, member, %{
          status: "exited",
          collect_reports: true,
          reports: %{"files" => [%{"name" => "a.jsonl", "size" => 10, "too_large" => false}]}
        })

      test_pid = self()

      stub(Transfers, :fetch_report, fn _client, _member, _exec, _name, dir, _deadline ->
        send(test_pid, {:fetching, self()})
        receive do: (:go -> :ok)
        File.mkdir_p!(dir)
        path = Path.join(dir, "r")
        File.write!(path, "0123456789")
        {:ok, %{path: path, size: 10, sha256: "abc"}}
      end)

      fetch =
        Task.async(fn -> OwnerRPC.call(ctx.owner, {:fetch_report, exec.id, "a.jsonl"}, 5_000) end)

      assert_receive {:fetching, fetcher}
      assert Spool.reserved_bytes(ctx.account.id) == Config.report_max_bytes()
      send(fetcher, :go)
      assert {:ok, %{size: 10}} = Task.await(fetch)
      assert Spool.reserved_bytes(ctx.account.id) == 10

      # A new exec on the member invalidates the report and its reservation.
      assert {:ok, _} = start_exec(ctx, member)
      assert Spool.reserved_bytes(ctx.account.id) == 0
    end

    test "a report download is refused with busy when the spool budget is exhausted", ctx do
      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.merge(ctx.original, spool_max_bytes: 1_048_576)
      )

      ready!(ctx.m1)

      exec =
        exec_fixture(ctx.session, Repo.reload!(ctx.m1), %{
          status: "exited",
          collect_reports: true,
          reports: %{"files" => [%{"name" => "a.jsonl", "size" => 10, "too_large" => false}]}
        })

      reject(Transfers, :fetch_report, 6)
      assert OwnerRPC.call(ctx.owner, {:fetch_report, exec.id, "a.jsonl"}) == {:error, :busy}
    end
  end

  describe "hydration" do
    test "copies to one session's members run one at a time", ctx do
      stub_hydration()
      assert upload!(ctx, archive()) == :ok

      assert_receive {:hydrating, first, task}
      refute_receive {:hydrating, _, _}, 300
      send(task, :go)
      assert_receive {:hydrating, second, task2}
      assert Enum.sort([first, second]) == Enum.sort([ctx.m1.id, ctx.m2.id])
      send(task2, :go)

      for id <- [first, second],
          do: assert_receive({:pool_session_event, "member_ready", %{member_id: ^id}})
    end

    test "a hydration task that dies without reporting resets the member", ctx do
      stub_hydration(:die)
      assert upload!(ctx, archive()) == :ok

      assert_receive {:hydrating, id, _task}

      assert_receive {:pool_session_event, "member_lost", %{member_id: ^id, reason: reason}},
                     2_000

      assert reason =~ "exited"
      assert Repo.reload!(Repo.get!(Member, id)).state == "resetting"
    end

    test "a member granted without a broadcast is hydrated at the next renewal", ctx do
      stub_hydration(:ok)
      assert upload!(ctx, archive()) == :ok
      for _ <- 1..2, do: assert_receive({:hydrating, _, _})

      # Leased directly, as if the member_granted broadcast was lost.
      late = member_fixture(ctx.pool)

      Repo.update_all(Ecto.Query.where(Member, id: ^late.id),
        set: [state: "leased", session_id: ctx.session.id, lease_generation: 1]
      )

      late_id = late.id
      refute_received {:hydrating, ^late_id, _}
      send(ctx.pid, :renew)
      assert_receive {:hydrating, ^late_id, _}
    end

    test "a report task that dies answers its waiters instead of hanging", ctx do
      ready!(ctx.m1)

      exec =
        exec_fixture(ctx.session, Repo.reload!(ctx.m1), %{
          status: "exited",
          collect_reports: true,
          reports: %{"files" => [%{"name" => "a.jsonl", "size" => 10, "too_large" => false}]}
        })

      stub(Transfers, :fetch_report, fn _client, _member, _exec, _name, _dir, _deadline ->
        Process.exit(self(), :kill)
      end)

      assert OwnerRPC.call(ctx.owner, {:fetch_report, exec.id, "a.jsonl"}) ==
               {:error, :transfer_failed}

      assert Spool.reserved_bytes(ctx.account.id) == 0
    end
  end

  describe "database errors and the lease" do
    test "a failed lease renewal is retried instead of crashing the coordinator", ctx do
      stub(Sessions, :renew_owner_lease, fn _sid, _owner ->
        raise DBConnection.ConnectionError, "connection not available"
      end)

      log =
        capture_log(fn ->
          send(ctx.pid, :renew)
          assert OwnerRPC.call(ctx.owner, :ping) == :pong
        end)

      assert log =~ "lease renewal failed"
      assert Process.alive?(ctx.pid)
    end

    test "a database error while admitting an exec is answered, not a crash", ctx do
      ready!(ctx.m1)

      stub(Execs, :admit, fn _session, _request, _owner, _deadline ->
        raise DBConnection.ConnectionError, "connection not available"
      end)

      # The channel answers any non-string error as `unavailable`.
      capture_log(fn ->
        assert start_exec(ctx, ctx.m1) == {:error, :owner_unavailable}
      end)

      assert OwnerRPC.call(ctx.owner, :ping) == :pong
    end

    test "past its lease deadline it admits no work, then stops", ctx do
      ready!(ctx.m1)
      :sys.replace_state(ctx.pid, &%{&1 | lease_deadline: System.monotonic_time(:millisecond)})

      assert start_exec(ctx, ctx.m1) == {:error, "unavailable"}
      assert OwnerRPC.call(ctx.owner, {:upload_begin, self()}) == {:error, :owner_unavailable}

      stub(Sessions, :renew_owner_lease, fn _sid, _owner ->
        raise DBConnection.ConnectionError, "connection not available"
      end)

      ref = Process.monitor(ctx.pid)

      capture_log(fn ->
        send(ctx.pid, :renew)
        assert_receive {:DOWN, ^ref, :process, _, :normal}
      end)
    end
  end

  describe "a coordinator never outlives its session row" do
    test "an insert that raises stops the coordinator", ctx do
      before = DynamicSupervisor.count_children(GoodFlows.Pools.CoordinatorSupervisor).active
      # An API key that does not exist: the insert violates its foreign key.
      ghost = %{ctx.key | id: Ecto.UUID.generate()}

      assert_raise Ecto.ConstraintError, fn ->
        Sessions.create(ctx.account, ctx.project, "p", ghost, %{
          "max_members" => 1,
          "acquire_timeout_ms" => 60_000
        })
      end

      assert DynamicSupervisor.count_children(GoodFlows.Pools.CoordinatorSupervisor).active ==
               before
    end

    test "a coordinator that is never activated stops itself" do
      {:ok, pid} =
        SessionCoordinator.start(%{
          session_id: Ecto.UUID.generate(),
          owner_id: Executions.new_owner_id(),
          account_id: Ecto.UUID.generate(),
          token: "sprites_secret_token_a1b2",
          activation_timeout_ms: 50
        })

      ref = Process.monitor(pid)

      capture_log(fn -> assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000 end)
    end
  end
end
