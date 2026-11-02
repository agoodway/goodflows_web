defmodule GoodFlowsWeb.PoolProtocolDocTest do
  # Checks docs/pool-protocol.md's example payloads against what the
  # channel really sends: same keys (recursively), and the documented exec
  # request is accepted.
  use GoodFlowsWeb.ChannelCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FakeExec
  alias GoodFlows.Pools.{Execs, Grants, Member, Sessions}
  alias GoodFlows.Repo
  alias GoodFlowsWeb.{PoolSocket, SessionChannel}

  @doc_path Path.expand("../../../docs/pool-protocol.md", __DIR__)

  setup :set_mimic_global

  defp examples do
    ~r/<!-- payload: (\w+) -->\s*```json\n(.*?)```/s
    |> Regex.scan(File.read!(@doc_path), capture: :all_but_first)
    |> Map.new(fn [name, json] -> {name, Jason.decode!(json)} end)
  end

  # Key structure: maps become sorted key lists (recursively), lists use
  # their first element.
  defp shape(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), shape(v)} end) |> Enum.sort()

  defp shape([first | _]), do: [shape(first)]
  defp shape(_scalar), do: :scalar

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  setup do
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)

    FakeExec.stub!(self(), fn _argv ->
      {:ok,
       %{
         outputs: "{}",
         outputs_truncated: false,
         reports: [%{"name" => "a.jsonl", "size" => 1, "too_large" => false}],
         reports_truncated: false
       }}
    end)

    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    {key, _} = api_key_fixture(Accounts.get_account_user(user, account), %{type: :private})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "p", "max_members" => 3})
    member_fixture(pool)

    {:ok, session} =
      Sessions.create(account, project, "p", key, %{
        "max_members" => 2,
        "acquire_timeout_ms" => 60_000
      })

    [member] = Sessions.members(session.id)

    Repo.update_all(Ecto.Query.where(Member, id: ^member.id),
      set: [workspace_ready_generation: member.lease_generation]
    )

    socket = socket(PoolSocket, nil, %{api_key_id: key.id, account_id: account.id})
    %{session: session, member: member, socket: socket, pool: pool}
  end

  test "every documented payload has the keys the server sends", ctx do
    examples = examples()

    assert Enum.sort(Map.keys(examples)) ==
             ~w(exec_request exit gap join member_granted member_lost member_ready output session_ended)

    # exec_request: the documented request is valid.
    assert {:ok, _} =
             Execs.validate_request(%{examples["exec_request"] | "member_id" => ctx.member.id})

    {:ok, _reply, socket} = join(ctx.socket, SessionChannel, "pool_session:#{ctx.session.id}")

    ref =
      push(socket, "exec", %{
        "member_id" => ctx.member.id,
        "command" => "x",
        "collect_reports" => true
      })

    assert_reply ref, :ok, %{exec_id: exec_id}
    {:ok, reply, second} = join(ctx.socket, SessionChannel, "pool_session:#{ctx.session.id}")
    Process.unlink(second.channel_pid)
    assert shape(json(reply)) == shape(examples["join"])

    assert_receive {:exec_started, pid, _}
    FakeExec.emit(pid, {:stdout, "hello\n"})
    assert_push "output", output
    assert shape(json(output)) == shape(examples["output"])
    FakeExec.emit(pid, {:exit, 0})
    assert_push "exit", exit
    assert shape(json(exit)) == shape(examples["exit"])

    # gap: resume from a persisted exit with missing output.
    other =
      exec_fixture(ctx.session, ctx.member, %{status: "exited", exit_code: 0, final_output_seq: 5})

    ref = push(socket, "resume", %{"execs" => [%{"exec_id" => other.id, "last_seq" => -1}]})
    assert_reply ref, :ok
    assert_push "gap", gap
    assert shape(json(gap)) == shape(examples["gap"])
    _ = exec_id

    # member_granted / member_ready / member_lost.
    new_member = member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    assert_push "member_granted", granted
    assert shape(json(granted)) == shape(examples["member_granted"])

    leased = Repo.get!(Member, new_member.id)
    :ok = Sessions.mark_member_ready(leased.id, ctx.session.id, leased.lease_generation)
    assert_push "member_ready", ready
    assert shape(json(ready)) == shape(examples["member_ready"])

    :ok = Sessions.member_lost(leased.id, ctx.session.id, leased.lease_generation, :reset, "x")
    assert_push "member_lost", lost
    assert shape(json(lost)) == shape(examples["member_lost"])

    Process.unlink(socket.channel_pid)
    # Both channels stop on session_ended; waiting for them keeps their
    # final heartbeat inside the sandbox's lifetime.
    refs = for pid <- [socket.channel_pid, second.channel_pid], do: Process.monitor(pid)
    ref = push(socket, "release", %{})
    assert_reply ref, :ok
    assert_push "session_ended", ended
    assert shape(json(ended)) == shape(examples["session_ended"])
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2_000)
  end
end
