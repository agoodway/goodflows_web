defmodule GoodFlowsWeb.SessionChannelTest do
  use GoodFlowsWeb.ChannelCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FakeExec
  alias GoodFlows.Pools.{Exec, Member, Reconciler, Session, Sessions}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Executions
  alias GoodFlows.Spry.Sprites, as: Wrapper
  alias GoodFlowsWeb.{PoolSocket, SessionChannel}

  setup :set_mimic_global

  setup do
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    FakeExec.stub!(self())
    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    au = Accounts.get_account_user(user, account)
    {key, _sk} = api_key_fixture(au, %{type: :private})
    {other_key, _} = api_key_fixture(au, %{type: :private})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "p", "max_members" => 4})
    members = for _ <- 1..2, do: member_fixture(pool)

    {:ok, session} =
      Sessions.create(account, project, "p", key, %{
        "max_members" => 2,
        "acquire_timeout_ms" => 60_000
      })

    for m <- Sessions.members(session.id) do
      Repo.update_all(Ecto.Query.where(Member, id: ^m.id),
        set: [workspace_ready_generation: m.lease_generation]
      )
    end

    [m1, m2] = Enum.map(members, &Repo.reload!/1)

    # Runs before the sandbox owner stops (on_exit callbacks run in reverse):
    # the channels, exec servers, and coordinator of the session finish their
    # database work first, so none is cut off mid-query.
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
    Process.unlink(sup)
    on_exit(fn -> quiesce(sup) end)

    %{
      account: account,
      key: key,
      other_key: other_key,
      session: Repo.reload!(session),
      topic: "pool_session:#{session.id}",
      m1: m1,
      m2: m2,
      pool: pool,
      sup: sup
    }
  end

  # Channels run under a supervisor ExUnit does not stop and are unlinked
  # from the test process (`join_channel/2`), so the end of a test never
  # kills one mid-query (which would break the shared sandbox connection).
  # This on_exit callback runs before the sandbox owner stops: it stops the
  # channels gracefully, then the sessions' exec servers and coordinators.
  defp quiesce(sup) do
    for {_, pid, _, _} <- Supervisor.which_children(sup), is_pid(pid), do: stop_quietly(pid)
    stop_quietly(sup)

    owners =
      Enum.map(Repo.all(Exec), & &1.owner_id) ++ Enum.map(Repo.all(Session), & &1.owner_id)

    for owner <- owners,
        is_binary(owner),
        {:ok, pid} <- [Executions.lookup(owner)],
        do: stop_quietly(pid)
  end

  defp stop_quietly(pid) do
    GenServer.stop(pid, :shutdown, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp client_socket(ctx, key \\ nil) do
    socket =
      socket(PoolSocket, nil, %{api_key_id: (key || ctx.key).id, account_id: ctx.account.id})

    put_in(socket.private.phoenix_test_supervisor, ctx.sup)
  end

  defp join_channel(socket, topic) do
    case join(socket, SessionChannel, topic) do
      {:ok, reply, socket} ->
        Process.unlink(socket.channel_pid)
        {:ok, reply, socket}

      error ->
        error
    end
  end

  defp join!(ctx) do
    {:ok, reply, socket} = join_channel(client_socket(ctx), ctx.topic)
    {reply, socket}
  end

  # Polls instead of sleeping: the fake command forwards emitted events to
  # the exec server asynchronously.
  defp await_buffered(exec_id, seq, attempts \\ 200) do
    {:ok, server} = Executions.lookup(Repo.get!(Exec, exec_id).owner_id)
    {:ok, %{high_seq: high}} = GenServer.call(server, {:replay, seq})

    cond do
      high >= seq -> :ok
      attempts == 0 -> flunk("exec #{exec_id} never buffered seq #{seq}")
      true -> await_buffered(exec_id, seq, attempts - 1)
    end
  end

  defp await_exec_status(exec_id, status, attempts \\ 200) do
    cond do
      Repo.get!(Exec, exec_id).status == status -> :ok
      attempts == 0 -> flunk("exec #{exec_id} never became #{status}")
      true -> await_exec_status(exec_id, status, attempts - 1)
    end
  end

  defp start_exec(socket, payload) do
    ref = push(socket, "exec", payload)
    assert_reply ref, :ok, %{exec_id: exec_id}
    assert_receive {:exec_started, pid, info}
    {exec_id, pid, info}
  end

  describe "join" do
    test "replies with status, ready members, and running execs", ctx do
      {reply, socket} = join!(ctx)
      assert reply.status == "active"
      assert Enum.sort(Enum.map(reply.members, & &1.id)) == Enum.sort([ctx.m1.id, ctx.m2.id])
      assert Enum.all?(reply.members, & &1.ready)
      assert reply.execs == []

      {exec_id, _pid, _} =
        start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "make", "job" => "build"})

      {:ok, reply, _socket} = join_channel(client_socket(ctx), ctx.topic)
      assert [%{exec_id: ^exec_id, job: "build"}] = reply.execs
    end

    test "not_found, forbidden, and ended", ctx do
      other = account_fixture()

      assert {:error, %{reason: "not_found"}} =
               join(
                 socket(PoolSocket, nil, %{api_key_id: ctx.key.id, account_id: other.id}),
                 SessionChannel,
                 ctx.topic
               )

      assert {:error, %{reason: "not_found"}} =
               join_channel(client_socket(ctx), "pool_session:#{Ecto.UUID.generate()}")

      assert {:error, %{reason: "forbidden"}} =
               join_channel(client_socket(ctx, ctx.other_key), ctx.topic)

      Sessions.end_session(ctx.session.id, "expired", "client_disconnected")

      assert {:error, %{reason: "ended", end_reason: "client_disconnected"}} =
               join_channel(client_socket(ctx), ctx.topic)
    end

    test "joining and heartbeats refresh last_seen_at", ctx do
      stale = DateTime.add(DateTime.utc_now(), -50, :second)
      Repo.update_all(Ecto.Query.where(Session, id: ^ctx.session.id), set: [last_seen_at: stale])
      {_reply, socket} = join!(ctx)
      assert DateTime.diff(Repo.reload!(ctx.session).last_seen_at, stale) >= 49

      Repo.update_all(Ecto.Query.where(Session, id: ^ctx.session.id), set: [last_seen_at: stale])
      send(socket.channel_pid, :heartbeat)
      _ = :sys.get_state(socket.channel_pid)
      assert DateTime.diff(Repo.reload!(ctx.session).last_seen_at, stale) >= 49
    end

    test "a heartbeat after the key was revoked ends the session", ctx do
      {_reply, socket} = join!(ctx)
      Process.unlink(socket.channel_pid)
      {:ok, _} = Accounts.revoke_api_key(ctx.key)
      send(socket.channel_pid, :heartbeat)
      assert_push "session_ended", %{status: "expired", reason: "key_revoked"}
    end
  end

  describe "exec" do
    test "a shell command runs in /workspace with server-owned outputs, streaming output", ctx do
      {_reply, socket} = join!(ctx)

      {exec_id, pid, info} =
        start_exec(socket, %{
          "member_id" => ctx.m1.id,
          "command" => "cargo test --locked",
          "cwd" => ".",
          "env" => %{"A" => "1", "GOODFLOWS_OUTPUT" => "/tmp/x"},
          "job" => "test"
        })

      assert info.name == ctx.m1.name
      assert ["-c", prelude, "sh", "sh", "-c", "cargo test --locked"] = info.args
      assert prelude =~ "/tmp/gf-exec-#{exec_id}/outputs"
      assert info.opts[:dir] == "/workspace"
      env = Map.new(info.opts[:env])
      assert env["A"] == "1"
      assert env["GOODFLOWS_OUTPUT"] == "/tmp/gf-exec-#{exec_id}/outputs"
      refute Map.has_key?(env, "GOODFLOWS_REPORT_DIR")

      FakeExec.emit(pid, {:stdout, "out1"})
      FakeExec.emit(pid, {:stderr, <<0xFF, 0xFE>>})
      FakeExec.emit(pid, {:stdout, "out2"})
      FakeExec.emit(pid, {:exit, 0})

      assert_push "output", %{exec_id: ^exec_id, seq: 0, stream: "stdout", data: d0}
      assert_push "output", %{seq: 1, stream: "stderr", data: d1}
      assert_push "output", %{seq: 2, stream: "stdout"}
      assert Base.decode64!(d0) == "out1"
      assert Base.decode64!(d1) == <<0xFF, 0xFE>>
      assert_push "exit", %{exec_id: ^exec_id, status: "exited", exit_code: 0, outputs: nil}

      exec = Repo.get!(Exec, exec_id)
      assert exec.final_output_seq == 2
      assert {exec.bytes_stdout, exec.bytes_stderr} == {8, 2}
    end

    test "argv runs directly; collect_reports sets the report dir", ctx do
      {_reply, socket} = join!(ctx)

      {exec_id, _pid, info} =
        start_exec(socket, %{
          "member_id" => ctx.m1.id,
          "argv" => ["mix", "test"],
          "cwd" => "app/sub",
          "collect_reports" => true
        })

      assert ["-c", _prelude, "sh", "mix", "test"] = info.args
      assert info.opts[:dir] == "/workspace/app/sub"
      assert Map.new(info.opts[:env])["GOODFLOWS_REPORT_DIR"] == "/tmp/gf-exec-#{exec_id}/reports"
    end

    test "outputs and the report manifest come from collect and are persisted", ctx do
      outputs = :binary.copy("x", 65_537)

      FakeExec.stub!(self(), fn argv ->
        assert "collect" in argv

        {:ok,
         %{
           outputs: outputs,
           outputs_truncated: true,
           reports: [%{"name" => "a.jsonl", "size" => 3, "too_large" => false}],
           reports_truncated: false,
           reports_skipped: 2
         }}
      end)

      {_reply, socket} = join!(ctx)

      {exec_id, pid, _} =
        start_exec(socket, %{
          "member_id" => ctx.m1.id,
          "command" => "x",
          "collect_reports" => true
        })

      FakeExec.emit(pid, {:exit, 3})

      assert_push "exit", %{
        status: "exited",
        exit_code: 3,
        outputs: encoded,
        outputs_truncated: true,
        reports: reports
      }

      assert Base.decode64!(encoded) == outputs
      assert %{files: [%{"name" => "a.jsonl"}], truncated: false, skipped: 2} = reports
      assert byte_size(Repo.get!(Exec, exec_id).outputs) == 65_537
    end

    test "rejections run nothing", ctx do
      {_reply, socket} = join!(ctx)

      cases = [
        {%{"member_id" => ctx.m1.id, "command" => "a", "argv" => ["b"]}, "invalid_request"},
        {%{"member_id" => ctx.m1.id}, "invalid_request"},
        {%{"member_id" => ctx.m1.id, "command" => "a", "timeout_ms" => 0}, "invalid_request"},
        {%{"member_id" => ctx.m1.id, "command" => "a", "cwd" => "/etc"}, "invalid_request"},
        {%{"member_id" => ctx.m1.id, "command" => "a", "cwd" => "a/../../b"}, "invalid_request"},
        {%{"member_id" => Ecto.UUID.generate(), "command" => "a"}, "not_granted"}
      ]

      for {payload, reason} <- cases do
        ref = push(socket, "exec", payload)
        assert_reply ref, :error, %{reason: ^reason}
      end

      ref = push(socket, "exec", %{"member_id" => ctx.m1.id, "command" => "a", "argv" => ["b"]})
      assert_reply ref, :error, %{fields: ["command", "argv"]}

      Repo.update_all(Ecto.Query.where(Member, id: ^ctx.m2.id),
        set: [workspace_ready_generation: nil]
      )

      ref = push(socket, "exec", %{"member_id" => ctx.m2.id, "command" => "a"})
      assert_reply ref, :error, %{reason: "member_not_ready"}

      refute_received {:exec_started, _, _}
      assert Repo.aggregate(Exec, :count) == 0
    end

    test "a second exec on a busy member is member_busy, also when concurrent", ctx do
      {_reply, socket} = join!(ctx)
      {:ok, _reply, socket2} = join_channel(client_socket(ctx), ctx.topic)

      r1 = push(socket, "exec", %{"member_id" => ctx.m1.id, "command" => "a"})
      r2 = push(socket2, "exec", %{"member_id" => ctx.m1.id, "command" => "b"})
      replies = for ref <- [r1, r2], do: receive_reply(ref)
      assert Enum.sort(Enum.map(replies, &elem(&1, 0))) == [:error, :ok]
      assert {:error, %{reason: "member_busy"}} in replies
      assert Repo.aggregate(Exec, :count) == 1
    end

    defp receive_reply(ref) do
      receive do
        %Phoenix.Socket.Reply{ref: ^ref, status: status, payload: payload} -> {status, payload}
      after
        2_000 -> flunk("no reply")
      end
    end

    test "timeout kills the exec as timed_out", ctx do
      {_reply, socket} = join!(ctx)

      {exec_id, pid, _} =
        start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9", "timeout_ms" => 50})

      ref = Process.monitor(pid)
      assert_push "exit", %{exec_id: ^exec_id, status: "timed_out", exit_code: nil}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :killed}
    end

    test "cancel kills it as cancelled; cancelling again is a no-op", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})

      ref = push(socket, "cancel", %{"exec_id" => exec_id})
      assert_reply ref, :ok
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled"}

      ref = push(socket, "cancel", %{"exec_id" => exec_id})
      assert_reply ref, :ok
      refute_push "exit", _
    end

    test "release cancels running execs, pushing exit before session_ended", ctx do
      {_reply, socket} = join!(ctx)
      Process.unlink(socket.channel_pid)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})

      ref = push(socket, "release", %{})
      assert_reply ref, :ok
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled"}
      assert_push "session_ended", %{status: "released", reason: nil}
    end
  end

  describe "resume" do
    test "more than 1,000 entries are refused before any lookup", ctx do
      {_reply, socket} = join!(ctx)
      entry = %{"exec_id" => Ecto.UUID.generate(), "last_seq" => -1}
      ref = push(socket, "resume", %{"execs" => List.duplicate(entry, 1_001)})
      assert_reply ref, :error, %{reason: "invalid_request", fields: ["execs"]}

      ref = push(socket, "resume", %{"execs" => List.duplicate(entry, 1_000)})
      assert_reply ref, :ok
    end

    test "after a short drop, output after last_seq is replayed with no gap", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})
      for i <- 0..41, do: FakeExec.emit(pid, {:stdout, "line #{i}\n"})
      assert_push "output", %{seq: 41}

      # The socket drops; the exec keeps running and producing output.
      Process.unlink(socket.channel_pid)
      leave_ref = leave(socket)
      assert_reply leave_ref, :ok
      for i <- 42..45, do: FakeExec.emit(pid, {:stdout, "line #{i}\n"})
      await_buffered(exec_id, 45)

      {_reply, socket} = join!(ctx)
      ref = push(socket, "resume", %{"execs" => [%{"exec_id" => exec_id, "last_seq" => 41}]})
      assert_reply ref, :ok
      refute_push "gap", _
      for seq <- 42..45, do: assert_push("output", %{seq: ^seq})

      FakeExec.emit(pid, {:stdout, "live"})
      assert_push "output", %{seq: 46}
      FakeExec.emit(pid, {:exit, 0})
      assert_push "exit", %{exec_id: ^exec_id, status: "exited"}
    end

    test "evicted output is reported as a gap before the retained output", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.put(original, :exec_buffer_bytes, 100)
      )

      {_reply, socket} = join!(ctx)
      Process.unlink(socket.channel_pid)
      {exec_id, pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})
      leave_ref = leave(socket)
      assert_reply leave_ref, :ok

      # 20 chunks of 10 bytes: only the last 10 fit in 100 bytes.
      for i <- 0..19, do: FakeExec.emit(pid, {:stdout, String.pad_leading("#{i}", 10, "0")})
      FakeExec.emit(pid, {:exit, 0})
      await_exec_status(exec_id, "exited")

      {_reply, socket} = join!(ctx)
      ref = push(socket, "resume", %{"execs" => [%{"exec_id" => exec_id, "last_seq" => -1}]})
      assert_reply ref, :ok
      assert_push "gap", %{exec_id: ^exec_id, from_seq: 0, to_seq: 9}
      for seq <- 10..19, do: assert_push("output", %{seq: ^seq})
      assert_push "exit", %{status: "exited"}
    end

    test "a persisted exit is replayed after the exec server stopped, with a gap", ctx do
      session = ctx.session

      exec =
        exec_fixture(session, ctx.m1, %{
          status: "exited",
          exit_code: 0,
          final_output_seq: 50,
          duration_ms: 5
        })

      {_reply, socket} = join!(ctx)
      ref = push(socket, "resume", %{"execs" => [%{"exec_id" => exec.id, "last_seq" => 41}]})
      assert_reply ref, :ok
      exec_id = exec.id
      assert_push "gap", %{exec_id: ^exec_id, from_seq: 42, to_seq: 50}
      assert_push "exit", %{exec_id: ^exec_id, status: "exited", exit_code: 0}
    end

    test "output arriving while replay is fetched is neither lost nor duplicated", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})
      Process.unlink(socket.channel_pid)
      leave_ref = leave(socket)
      assert_reply leave_ref, :ok

      {_reply, socket} = join!(ctx)
      emitter = Task.async(fn -> for i <- 0..199, do: FakeExec.emit(pid, {:stdout, "#{i}"}) end)
      ref = push(socket, "resume", %{"execs" => [%{"exec_id" => exec_id, "last_seq" => -1}]})
      Task.await(emitter)
      assert_reply ref, :ok
      FakeExec.emit(pid, {:exit, 0})
      assert_push "exit", %{status: "exited"}, 2_000

      seqs = collect_seqs([])
      assert seqs == Enum.to_list(0..199)
    end

    defp collect_seqs(acc) do
      receive do
        %Phoenix.Socket.Message{event: "output", payload: %{seq: seq}} ->
          collect_seqs([seq | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "a confirmed exec owner loss ends the exec error/owner_lost and resets the member",
         ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})
      {:ok, server} = Executions.lookup(Repo.get!(Exec, exec_id).owner_id)
      Process.exit(server, :kill)

      assert_push "exit", %{exec_id: ^exec_id, status: "error", error_reason: "owner_lost"}, 2_000
      assert_push "member_lost", %{member_id: _}
      assert Repo.reload!(ctx.m1).state == "resetting"
    end

    test "the reconciler recovers an exec whose owner probe is a confirmed loss", ctx do
      {_reply, socket} = join!(ctx)

      exec =
        exec_fixture(ctx.session, ctx.m1, %{
          # This node and boot, but never registered: a confirmed loss.
          owner_id: Executions.new_owner_id(),
          operation_deadline_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        })

      ref = push(socket, "resume", %{"execs" => [%{"exec_id" => exec.id, "last_seq" => -1}]})
      assert_reply ref, :ok

      Reconciler.reconcile()
      assert %{status: "error", error_reason: "owner_lost"} = Repo.reload!(exec)
      exec_id = exec.id
      assert_push "exit", %{exec_id: ^exec_id, status: "error", error_reason: "owner_lost"}
      assert_push "member_lost", %{member_id: _}
      assert Repo.reload!(ctx.m1).state == "resetting"
    end

    test "an unreachable exec owner keeps the lease until the hard deadline", ctx do
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      exec =
        exec_fixture(ctx.session, ctx.m1, %{
          owner_id: "far@away|boot|#{Ecto.UUID.generate()}",
          operation_deadline_at: future
        })

      _ = String.to_atom("far@away")

      Application.put_env(:good_flows, :pools_remote_call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      on_exit(fn -> Application.delete_env(:good_flows, :pools_remote_call) end)

      Reconciler.reconcile()
      assert Repo.reload!(exec).status == "running"
      assert Repo.reload!(ctx.m1).state == "leased"

      Repo.update_all(Ecto.Query.where(Exec, id: ^exec.id),
        set: [operation_deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      Reconciler.reconcile()
      assert %{status: "error", error_reason: "owner_lost"} = Repo.reload!(exec)
      assert Repo.reload!(ctx.m1).state == "resetting"
    end
  end

  describe "exec lifecycle" do
    test "after a credential replacement, execs keep the credential captured at creation",
         ctx do
      test_pid = self()

      stub(Wrapper, :spawn_streaming, fn client, _name, _cmd, _args, _owner, _ ->
        send(test_pid, {:exec_client, client})
        {:ok, %{ref: make_ref(), pid: spawn(fn -> Process.sleep(:infinity) end)}}
      end)

      {:ok, _} =
        GoodFlows.Spry.put_credential(ctx.account, %{"token" => "sprites_new_token_z9y8"})

      {_reply, socket} = join!(ctx)

      ref = push(socket, "exec", %{"member_id" => ctx.m1.id, "command" => "x"})
      assert_reply ref, :ok, %{exec_id: _}
      assert_receive {:exec_client, client}
      assert client == Wrapper.client(token())
      refute client == Wrapper.client("sprites_new_token_z9y8")
    end

    test "the prelude records the process group and a cancel kills it before the exit", ctx do
      {_reply, socket} = join!(ctx)

      {exec_id, _pid, info} =
        start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})

      ["-c", prelude | _] = info.args
      assert prelude =~ "setsid"
      assert prelude =~ "/tmp/gf-exec-#{exec_id}/pgid"

      ref = push(socket, "cancel", %{"exec_id" => exec_id})
      assert_receive {:remote_kill, name, line}
      assert name == ctx.m1.name
      assert line =~ "/tmp/gf-exec-#{exec_id}/pgid"
      assert line =~ "kill -KILL"
      assert_reply ref, :ok
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled"}
    end

    test "a timeout also kills the remote process group", ctx do
      {_reply, socket} = join!(ctx)

      {exec_id, _pid, _} =
        start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x", "timeout_ms" => 30})

      assert_receive {:remote_kill, _name, line}, 2_000
      assert line =~ exec_id
      assert_push "exit", %{exec_id: ^exec_id, status: "timed_out"}, 2_000
    end

    test "a remote process that cannot be confirmed dead gets its member reset", ctx do
      stub(Wrapper, :exec, fn _client, _name, _line, _opts ->
        {:ok, %{exit_code: 1, output: "", output_truncated: false}}
      end)

      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})

      ref = push(socket, "cancel", %{"exec_id" => exec_id})
      assert_reply ref, :ok
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled"}
      assert_push "member_lost", %{member_id: member_id, reason: "exec could not be stopped"}
      assert member_id == ctx.m1.id
      assert Repo.reload!(ctx.m1).state == "resetting"
    end

    test "collect runs off the exec server, which keeps answering replay meanwhile", ctx do
      test_pid = self()

      FakeExec.stub!(self(), fn _argv ->
        send(test_pid, {:collecting, self()})

        receive do
          :go ->
            {:ok,
             %{outputs: "o", outputs_truncated: false, reports: [], reports_truncated: false}}
        end
      end)

      {_reply, socket} = join!(ctx)
      {exec_id, pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})
      FakeExec.emit(pid, {:stdout, "a"})
      FakeExec.emit(pid, {:exit, 0})
      assert_receive {:collecting, collector}

      {:ok, server} = Executions.lookup(Repo.get!(Exec, exec_id).owner_id)
      assert {:ok, %{high_seq: 0, exit: nil}} = GenServer.call(server, {:replay, -1}, 500)

      send(collector, :go)
      assert_push "exit", %{exec_id: ^exec_id, status: "exited", outputs: outputs}
      assert Base.decode64!(outputs) == "o"
    end

    test "outputs are collected after a cancel too, and a failed collect is flagged", ctx do
      FakeExec.stub!(self(), fn _argv -> {:error, %{status: nil, message: "gone"}} end)
      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})

      ref = push(socket, "cancel", %{"exec_id" => exec_id})
      assert_reply ref, :ok
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled", collect_failed: true}
      assert Repo.get!(Exec, exec_id).collect_failed
    end

    test "an exec server that fails to start leaves no running row", ctx do
      stub(Wrapper, :spawn_streaming, fn _, _, _, _, _, _ -> raise "boom" end)
      {_reply, socket} = join!(ctx)

      ref = push(socket, "exec", %{"member_id" => ctx.m1.id, "command" => "x"})
      assert_reply ref, :error, %{reason: "unavailable"}, 2_000
      assert [%Exec{status: "error", error_reason: "exec_failed"}] = Repo.all(Exec)
    end

    test "execs end error/owner_lost when their coordinator stops", ctx do
      {_reply, socket} = join!(ctx)
      Process.unlink(socket.channel_pid)
      {exec_id, pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})
      stream = Process.monitor(pid)
      {:ok, server} = Executions.lookup(Repo.get!(Exec, exec_id).owner_id)
      server_ref = Process.monitor(server)

      {:ok, coordinator} = Executions.lookup(ctx.session.owner_id)
      Process.exit(coordinator, :kill)

      assert_receive {:DOWN, ^stream, :process, _, _}, 2_000
      assert_receive {:remote_kill, _name, _line}, 2_000
      assert_receive {:DOWN, ^server_ref, :process, _, _}, 2_000
      assert %{status: "error", error_reason: "owner_lost"} = Repo.get!(Exec, exec_id)
    end

    test "the exec reply precedes its output", ctx do
      stub(Wrapper, :spawn_streaming, fn _client, _name, _cmd, _args, owner, _ ->
        ref = make_ref()
        send(owner, {:sprites_stream, ref, {:stdout, "early"}})
        {:ok, %{ref: ref, pid: spawn(fn -> Process.sleep(:infinity) end)}}
      end)

      {_reply, socket} = join!(ctx)
      ref = push(socket, "exec", %{"member_id" => ctx.m1.id, "command" => "x"})

      first =
        receive do
          %Phoenix.Socket.Reply{ref: ^ref} = reply -> reply
          %Phoenix.Socket.Message{event: "output"} = message -> message
        after
          2_000 -> flunk("neither reply nor output")
        end

      assert %Phoenix.Socket.Reply{status: :ok} = first
      assert_push "output", %{seq: 0}
    end

    test "live output that skips ahead and an exit past the last seq push gaps", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})

      send(
        socket.channel_pid,
        {:pool_exec_event, "output", %{exec_id: exec_id, seq: 3, stream: "stdout", data: ""}}
      )

      assert_push "gap", %{exec_id: ^exec_id, from_seq: 0, to_seq: 2}
      assert_push "output", %{seq: 3}

      send(
        socket.channel_pid,
        {:pool_exec_event, "exit", %{exec_id: exec_id, status: "exited", final_output_seq: 6}}
      )

      assert_push "gap", %{exec_id: ^exec_id, from_seq: 4, to_seq: 6}
      assert_push "exit", %{exec_id: ^exec_id}

      # Output after the exit is dropped.
      send(
        socket.channel_pid,
        {:pool_exec_event, "output", %{exec_id: exec_id, seq: 9, stream: "stdout", data: ""}}
      )

      refute_push "output", _
      refute_push "gap", _
    end

    test "resuming an ended exec twice pushes its exit once", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "x"})
      FakeExec.emit(pid, {:exit, 0})
      assert_push "exit", %{exec_id: ^exec_id}

      for _ <- 1..2 do
        ref = push(socket, "resume", %{"execs" => [%{"exec_id" => exec_id, "last_seq" => -1}]})
        assert_reply ref, :ok
      end

      refute_push "exit", _
    end

    test "execs listed at join get their exit before session_ended without a resume", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})
      Process.unlink(socket.channel_pid)
      leave(socket)

      {:ok, reply, socket} = join_channel(client_socket(ctx), ctx.topic)
      Process.unlink(socket.channel_pid)
      assert [%{exec_id: ^exec_id}] = reply.execs

      channel = Process.monitor(socket.channel_pid)
      Sessions.end_session(ctx.session.id, "released", nil)
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled"}
      assert_push "session_ended", %{status: "released"}
      assert_receive {:DOWN, ^channel, :process, _, _}
    end
  end

  describe "exec isolation" do
    # A ready session with its own member: in another pool of the same
    # account, or of another account.
    defp other_session(ctx, :same_account) do
      pool = pool_fixture(project_fixture(ctx.account), %{"max_members" => 1})
      member_fixture(pool)
      open_other_session(ctx.account, ctx.key, pool)
    end

    defp other_session(_ctx, :other_account) do
      user = user_fixture()

      {:ok, account} =
        Accounts.create_account(user, %{name: "Other #{System.unique_integer([:positive])}"})

      {key, _sk} = api_key_fixture(Accounts.get_account_user(user, account), %{type: :private})
      credential_fixture(account)
      pool = pool_fixture(project_fixture(account), %{"max_members" => 1})
      member_fixture(pool)
      open_other_session(account, key, pool)
    end

    defp open_other_session(account, key, pool) do
      project = GoodFlows.Repo.get!(GoodFlows.Projects.Project, pool.project_id)

      {:ok, session} =
        Sessions.create(account, project, pool.slug, key, %{
          "max_members" => 1,
          "acquire_timeout_ms" => 60_000
        })

      %{account: account, key: key, topic: "pool_session:#{session.id}"}
    end

    for scope <- [:same_account, :other_account] do
      test "cancel and resume cannot reach an exec of another session (#{scope})", ctx do
        {_reply, socket} = join!(ctx)

        {exec_id, pid, _} =
          start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})

        other = other_session(ctx, unquote(scope))
        other_ctx = %{ctx | account: other.account, key: other.key}
        {:ok, _reply, other_socket} = join_channel(client_socket(other_ctx), other.topic)

        ref = push(other_socket, "cancel", %{"exec_id" => exec_id})
        assert_reply ref, :error, %{reason: "not_found"}
        refute_receive {:remote_kill, _name, _line}, 100

        ref =
          push(other_socket, "resume", %{
            "execs" => [%{"exec_id" => exec_id, "last_seq" => -1}]
          })

        assert_reply ref, :ok
        refute_push "output", _
        refute_push "gap", _
        refute_push "exit", _

        # The exec still runs and still reports to its own session only.
        assert Repo.get!(Exec, exec_id).status == "running"
        FakeExec.emit(pid, {:stdout, "still here"})
        assert_push "output", %{exec_id: ^exec_id, seq: 0}
        refute_push "output", %{exec_id: ^exec_id}
      end
    end
  end

  describe "want and release_member" do
    test "want adjusts demand; release_member resets one member", ctx do
      {_reply, socket} = join!(ctx)

      ref = push(socket, "want", %{"wanted" => 0})
      assert_reply ref, :ok
      assert Repo.reload!(ctx.session).wanted == 0

      ref = push(socket, "want", %{"wanted" => 3})
      assert_reply ref, :error, %{reason: "invalid_request"}

      ref = push(socket, "release_member", %{"member_id" => ctx.m2.id})
      assert_reply ref, :ok
      assert Repo.reload!(ctx.m2).state == "resetting"

      ref = push(socket, "release_member", %{"member_id" => ctx.m2.id})
      assert_reply ref, :error, %{reason: "not_granted"}
    end

    test "release_member cancels the member's exec before resetting it", ctx do
      {_reply, socket} = join!(ctx)
      {exec_id, _pid, _} = start_exec(socket, %{"member_id" => ctx.m1.id, "command" => "sleep 9"})

      ref = push(socket, "release_member", %{"member_id" => ctx.m1.id})
      assert_push "exit", %{exec_id: ^exec_id, status: "cancelled"}
      assert_reply ref, :ok
      assert Repo.reload!(ctx.m1).state == "resetting"
      assert Repo.reload!(ctx.session).granted_count == 1
    end

    test "release_member is refused while the coordinator is unreachable", ctx do
      {_reply, socket} = join!(ctx)

      stub(GoodFlows.Pools.OwnerRPC, :call, fn
        _owner, {:release_member, _}, _timeout ->
          {:error, :owner_unavailable}

        owner, request, timeout ->
          call_original(GoodFlows.Pools.OwnerRPC, :call, [owner, request, timeout])
      end)

      ref = push(socket, "release_member", %{"member_id" => ctx.m1.id})
      assert_reply ref, :error, %{reason: "unavailable"}
      assert Repo.reload!(ctx.m1).state == "leased"
    end
  end
end
