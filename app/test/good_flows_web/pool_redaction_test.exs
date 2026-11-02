defmodule GoodFlowsWeb.PoolRedactionTest do
  # Not async: raises the global log level to :debug.
  use GoodFlowsWeb.ChannelCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FakeExec
  alias GoodFlows.Pools.{Exec, Execs, ExecServer, Member, OwnerRPC, SessionCoordinator, Sessions}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Executions
  alias GoodFlowsWeb.{PoolSocket, SessionChannel}

  @moduletag :capture_log

  @secret "SENTINEL-exec-secret-7c1d"
  @command "deploy --password #{@secret}"

  setup :set_mimic_global

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    FakeExec.stub!(self())
    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    {key, _} = api_key_fixture(Accounts.get_account_user(user, account), %{type: :private})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "p", "max_members" => 2})
    member_fixture(pool)

    {:ok, session} =
      Sessions.create(account, project, "p", key, %{
        "max_members" => 1,
        "acquire_timeout_ms" => 60_000
      })

    [member] = Sessions.members(session.id)

    Repo.update_all(Ecto.Query.where(Member, id: ^member.id),
      set: [workspace_ready_generation: member.lease_generation]
    )

    socket = socket(PoolSocket, nil, %{api_key_id: key.id, account_id: account.id})
    %{session: session, member: member, socket: socket}
  end

  defp refute_leaks(text) do
    refute text =~ @secret
    refute text =~ token()
  end

  test "exec, cancel, and failure paths never log or store env values, commands, or the token",
       ctx do
    log =
      capture_log([level: :debug], fn ->
        {:ok, _reply, socket} = join(ctx.socket, SessionChannel, "pool_session:#{ctx.session.id}")

        payload = %{
          "member_id" => ctx.member.id,
          "command" => @command,
          "env" => %{"API_TOKEN" => @secret, "token" => @secret}
        }

        ref = push(socket, "exec", payload)
        assert_reply ref, :ok, %{exec_id: exec_id}
        assert_receive {:exec_started, pid, _info}
        ref = push(socket, "cancel", %{"exec_id" => exec_id})
        assert_reply ref, :ok
        assert_push "exit", %{status: "cancelled"}

        ref = push(socket, "exec", %{payload | "command" => @command <> " again"})
        assert_reply ref, :ok, %{exec_id: _}
        assert_receive {:exec_started, pid2, _}
        FakeExec.emit(pid2, {:error, %{status: 500, message: "boom"}})
        assert_push "exit", %{status: "error"}

        # Rejected requests are not logged either.
        ref = push(socket, "exec", Map.put(payload, "argv", [@secret]))
        assert_reply ref, :error, %{reason: "invalid_request"}
        _ = pid
      end)

    refute_leaks(log)

    for table <- ~w(pool_execs pool_sessions pool_members) do
      %{rows: rows} = Repo.query!("SELECT * FROM #{table}")
      refute_leaks(inspect(rows, limit: :infinity, printable_limit: :infinity))
    end
  end

  test "crash reports of the coordinator and exec server carry no token", ctx do
    {:ok, coordinator} = Executions.lookup(ctx.session.owner_id)
    status = inspect(:sys.get_status(coordinator), limit: :infinity, printable_limit: :infinity)
    refute status =~ token()
    assert status =~ ":redacted"

    {:ok, request} =
      Execs.validate_request(%{"member_id" => ctx.member.id, "command" => "x"})

    {:ok, exec_id} = OwnerRPC.call(ctx.session.owner_id, {:start_exec, request})

    {:ok, server} =
      Executions.lookup(Repo.get!(Exec, exec_id).owner_id)

    refute inspect(:sys.get_status(server), limit: :infinity, printable_limit: :infinity) =~
             token()

    log =
      capture_log([level: :debug], fn ->
        Process.unlink(coordinator)
        ref = Process.monitor(coordinator)
        server_ref = Process.monitor(server)
        catch_exit(GenServer.call(coordinator, :not_a_request))
        assert_receive {:DOWN, ^ref, :process, _, _}
        # Its exec server ends the exec (owner_lost) and stops too.
        assert_receive {:DOWN, ^server_ref, :process, _, _}, 2_000
      end)

    assert log =~ "SessionCoordinator" or log =~ "terminating"
    refute_leaks(log)
  end

  test "a coordinator crash while starting an exec logs neither its command nor its env",
       ctx do
    stub(Execs, :admit, fn _session, _request, _owner, _deadline -> raise "admission blew up" end)
    {:ok, coordinator} = Executions.lookup(ctx.session.owner_id)
    Process.unlink(coordinator)
    ref = Process.monitor(coordinator)

    {:ok, request} =
      Execs.validate_request(%{
        "member_id" => ctx.member.id,
        "command" => @command,
        "env" => %{"API_TOKEN" => @secret}
      })

    log =
      capture_log([level: :debug], fn ->
        catch_exit(GenServer.call(coordinator, {:start_exec, request}))
        assert_receive {:DOWN, ^ref, :process, _, _}
        Process.sleep(50)
      end)

    assert log =~ "admission blew up"
    refute_leaks(log)
  end

  test "crash reports never carry an upload chunk or exec output" do
    from = {self(), make_ref()}
    ref = make_ref()
    chunk = "secret workspace bytes " <> @secret

    status =
      SessionCoordinator.format_status(%{
        state: %{client: :client},
        message: {:"$gen_call", from, {:upload_chunk, ref, chunk}}
      })

    assert status.message == {:"$gen_call", from, {:upload_chunk, ref, :redacted}}
    refute inspect(status) =~ @secret

    output =
      ExecServer.format_status(%{
        state: %{client: :client},
        message: {:sprites_stream, ref, {:stdout, "printed " <> @secret}}
      })

    assert output.message == {:sprites_stream, ref, {:stdout, :redacted}}
    refute inspect(output) =~ @secret
  end
end
