defmodule GoodFlows.Pools.ShutdownDrainTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FakeExec

  alias GoodFlows.Pools.{
    Events,
    Exec,
    Execs,
    Member,
    OwnerRPC,
    Session,
    Sessions,
    ShutdownDrain,
    Spool
  }

  setup :set_mimic_global

  setup do
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

    %{account: account, project: project, key: key, session: session, member: member}
  end

  test "it starts ahead of the coordinator and exec supervisors, so it stops after them" do
    children =
      GoodFlows.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    index = &Enum.find_index(children, fn id -> id == &1 end)
    assert index.(ShutdownDrain) < index.(GoodFlows.Pools.CoordinatorSupervisor)
    assert index.(GoodFlows.Pools.CoordinatorSupervisor) < index.(GoodFlows.Pools.ExecSupervisor)
    assert index.(GoodFlows.Pools.ExecSupervisor) < index.(GoodFlowsWeb.Endpoint)
  end

  test "draining ends local sessions as owner lost, then refuses sessions, execs, and uploads",
       ctx do
    {:ok, request} =
      Execs.validate_request(%{"member_id" => ctx.member.id, "command" => "sleep 9"})

    {:ok, exec_id} = OwnerRPC.call(ctx.session.owner_id, {:start_exec, request})
    Events.subscribe(Events.exec_topic(exec_id))
    Events.subscribe(Events.session_topic(ctx.session.id))
    File.mkdir_p!(Spool.session_dir(ctx.session.id))

    assert ShutdownDrain.drain() == 1

    assert_receive {:pool_exec_event, "exit", %{status: "error", error_reason: "owner_lost"}}

    assert_receive {:pool_session_event, "session_ended",
                    %{status: "expired", reason: "session_owner_lost"}}

    assert %Session{status: "expired", end_reason: "session_owner_lost"} =
             Repo.reload!(ctx.session)

    assert %Exec{status: "error", error_reason: "owner_lost"} = Repo.get!(Exec, exec_id)
    assert Repo.reload!(ctx.member).state == "resetting"
    refute File.exists?(Spool.boot_dir())

    refute ShutdownDrain.accepting?()

    assert Sessions.create(ctx.account, ctx.project, "p", ctx.key, %{
             "max_members" => 1,
             "acquire_timeout_ms" => 60_000
           }) == {:error, :draining}
  end

  test "a draining coordinator refuses new execs and uploads", ctx do
    :persistent_term.put({ShutdownDrain, :draining}, true)
    {:ok, request} = Execs.validate_request(%{"member_id" => ctx.member.id, "command" => "x"})
    assert OwnerRPC.call(ctx.session.owner_id, {:start_exec, request}) == {:error, "draining"}
    assert OwnerRPC.call(ctx.session.owner_id, {:upload_begin, self()}) == {:error, :busy}
    refute_received {:exec_started, _, _}
  end

  test "the application stops admission in prep_stop, before any child stops", ctx do
    assert ShutdownDrain.accepting?()
    assert GoodFlows.Application.prep_stop(:state) == :state
    assert ShutdownDrain.draining?()
    refute ShutdownDrain.accepting?()
    # Nothing is ended yet: coordinators still run until the drain.
    assert Repo.reload!(ctx.session).status in ["waiting", "active"]
  end

  test "terminate drains (an orderly shutdown of a drain process)", ctx do
    pid = start_supervised!({ShutdownDrain, name: :test_pool_drain})
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        :ok = stop_supervised(:test_pool_drain)
        assert_receive {:DOWN, ^ref, :process, _, _}
      end)

    assert log =~ "Pools: ended 1 session(s) owned by this node at shutdown"
    assert ShutdownDrain.draining?()
    assert Repo.reload!(ctx.session).end_reason == "session_owner_lost"
  end
end
