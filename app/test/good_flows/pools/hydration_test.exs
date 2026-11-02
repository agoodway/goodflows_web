defmodule GoodFlows.Pools.HydrationTest do
  # Session workspaces hydrated into members through the real gf-transfer
  # helper running locally (GoodFlows.FakeSprite).
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TarFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FakeSprite
  alias GoodFlows.Pools.{Events, Grants, Member, OwnerRPC, Sessions, Spool}
  alias GoodFlows.Spry.Executions

  @moduletag :helper_binary

  setup :set_mimic_global

  setup do
    test_pid = self()

    stub(PgFlow, :enqueue, fn job, %{"member_id" => id} ->
      send(test_pid, {:enqueued, job, id})
      {:ok, Ecto.UUID.generate()}
    end)

    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    {key, _} = api_key_fixture(Accounts.get_account_user(user, account), %{type: :private})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "p", "max_members" => 4})
    root = FakeSprite.root!()
    %{account: account, project: project, pool: pool, key: key, root: root}
  end

  defp start_session(ctx, max) do
    {:ok, session} =
      Sessions.create(ctx.account, ctx.project, "p", ctx.key, %{
        "max_members" => max,
        "acquire_timeout_ms" => 60_000
      })

    Events.subscribe(Events.session_topic(session.id))
    session
  end

  defp upload(session, bytes) do
    {:ok, ref} = OwnerRPC.call(session.owner_id, {:upload_begin, self()})
    :ok = OwnerRPC.call(session.owner_id, {:upload_chunk, ref, bytes})
    OwnerRPC.call(session.owner_id, {:upload_finish, ref}, 10_000)
  end

  defp workspace,
    do:
      tar_gz([
        {:dir, "src"},
        {:file, "src/main.c", "int main(){}"},
        {:file, "data.bin", :crypto.strong_rand_bytes(300_000)}
      ])

  defp extracted(ctx, member, file),
    do: File.read(Path.join(FakeSprite.path(ctx.root, member.name, "/workspace"), file))

  test "every granted member and a later grant receive the workspace", ctx do
    FakeSprite.stub!(ctx.root)
    [a, b] = for _ <- 1..2, do: member_fixture(ctx.pool)
    session = start_session(ctx, 3)

    assert :ok = upload(session, workspace())

    for member <- [a, b] do
      id = member.id
      assert_receive {:pool_session_event, "member_ready", %{member_id: ^id}}, 5_000
      assert {:ok, "int main(){}"} = extracted(ctx, member, "src/main.c")
      assert Member.ready?(Repo.reload!(member))
    end

    late = member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    id = late.id
    assert_receive {:pool_session_event, "member_granted", %{member_id: ^id}}
    assert_receive {:pool_session_event, "member_ready", %{member_id: ^id}}, 5_000
    assert {:ok, _} = extracted(ctx, late, "data.bin")
  end

  test "a member whose helper is missing becomes broken, is lost, and is replaced", ctx do
    [good, bad] = for _ <- 1..2, do: member_fixture(ctx.pool)
    FakeSprite.stub!(ctx.root, missing_helper: [bad.name])
    session = start_session(ctx, 2)

    assert :ok = upload(session, workspace())

    good_id = good.id
    bad_id = bad.id
    assert_receive {:pool_session_event, "member_ready", %{member_id: ^good_id}}, 5_000
    assert_receive {:pool_session_event, "member_lost", %{member_id: ^bad_id}}, 5_000
    assert Repo.reload!(bad).state == "broken"

    # The session keeps its place: the next idle member goes to it.
    replacement = member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    id = replacement.id
    assert_receive {:pool_session_event, "member_granted", %{member_id: ^id}}
    assert_receive {:pool_session_event, "member_ready", %{member_id: ^id}}, 5_000
    assert Repo.reload!(session).granted_count == 2
  end

  defp assert_replaced(ctx, session, lost, reason_part) do
    lost_id = lost.id

    assert_receive {:pool_session_event, "member_lost", %{member_id: ^lost_id, reason: reason}},
                   5_000

    assert reason =~ reason_part
    assert Repo.reload!(lost).state == "resetting"
    assert_received {:enqueued, GoodFlows.Pools.ResetMemberJob, ^lost_id}

    # The session keeps its place: the next idle member goes to it, hydrated.
    replacement = member_fixture(ctx.pool)
    Grants.grant(ctx.pool.id)
    id = replacement.id
    assert_receive {:pool_session_event, "member_granted", %{member_id: ^id}}
    assert_receive {:pool_session_event, "member_ready", %{member_id: ^id}}, 5_000
    assert Repo.reload!(session).granted_count == 2
  end

  test "extraction failing on one member loses it for reset and grants a replacement", ctx do
    [good, bad] = for _ <- 1..2, do: member_fixture(ctx.pool)
    FakeSprite.stub!(ctx.root)
    # A directory where the archive has a file: extraction fails there.
    File.mkdir_p!(FakeSprite.path(ctx.root, bad.name, "/workspace/data.bin/keep"))
    session = start_session(ctx, 2)

    assert :ok = upload(session, workspace())
    good_id = good.id
    assert_receive {:pool_session_event, "member_ready", %{member_id: ^good_id}}, 5_000
    assert_replaced(ctx, session, bad, "extract_failed")
    refute Member.ready?(Repo.reload!(bad))
  end

  test "a transfer that requires a restart loses the member and grants a replacement", ctx do
    [good, bad] = for _ <- 1..2, do: member_fixture(ctx.pool)
    FakeSprite.stub!(ctx.root)
    bad_name = bad.name

    stub(GoodFlows.Pools.Transfers, :receive_workspace, fn
      _client, %Member{name: ^bad_name}, _session_id, _workspace, _deadline, _opts ->
        {:error, "restart_required"}

      client, member, session_id, workspace, deadline, opts ->
        call_original(GoodFlows.Pools.Transfers, :receive_workspace, [
          client,
          member,
          session_id,
          workspace,
          deadline,
          opts
        ])
    end)

    session = start_session(ctx, 2)
    assert :ok = upload(session, workspace())
    good_id = good.id
    assert_receive {:pool_session_event, "member_ready", %{member_id: ^good_id}}, 5_000
    assert_replaced(ctx, session, bad, "restart_required")
  end

  test "exhausted transfer retries lose the member for reset", ctx do
    [member] = [member_fixture(ctx.pool)]
    FakeSprite.stub!(ctx.root, interrupt_after_writes: {1, 100})
    session = start_session(ctx, 1)

    assert :ok = upload(session, workspace())
    id = member.id
    assert_receive {:pool_session_event, "member_lost", %{member_id: ^id, reason: reason}}, 5_000
    assert reason =~ "retries exhausted"
    assert Repo.reload!(member).state == "resetting"
    assert_received {:enqueued, GoodFlows.Pools.ResetMemberJob, ^id}
    refute Member.ready?(Repo.reload!(member))
  end

  test "release racing extraction never marks the new lease ready", ctx do
    FakeSprite.stub!(ctx.root, delay_ms: 300)
    member = member_fixture(ctx.pool)
    session = start_session(ctx, 1)
    assert :ok = upload(session, workspace())

    # Released (and re-leased) while the helper is still starting.
    :ok = Sessions.release_member(Repo.reload!(session), member.id)

    Repo.update_all(Ecto.Query.where(Member, id: ^member.id),
      set: [
        state: "leased",
        session_id: session.id,
        lease_generation: Repo.reload!(member).lease_generation
      ]
    )

    id = member.id
    refute_receive {:pool_session_event, "member_ready", %{member_id: ^id}}, 2_000
    refute Member.ready?(Repo.reload!(member))
  end

  test "an upload after the session ended publishes nothing", ctx do
    FakeSprite.stub!(ctx.root)
    member_fixture(ctx.pool)
    session = start_session(ctx, 1)
    {:ok, ref} = OwnerRPC.call(session.owner_id, {:upload_begin, self()})
    :ok = OwnerRPC.call(session.owner_id, {:upload_chunk, ref, workspace()})

    Repo.update_all(Ecto.Query.where(GoodFlows.Pools.Session, id: ^session.id),
      set: [status: "released"]
    )

    assert OwnerRPC.call(session.owner_id, {:upload_finish, ref}, 10_000) ==
             {:error, :session_ended}

    refute_receive {:pool_session_event, "member_ready", _}, 500
  end

  test "the session spool is deleted when the session ends", ctx do
    FakeSprite.stub!(ctx.root)
    session = start_session(ctx, 1)
    assert :ok = upload(session, workspace())
    dir = Spool.session_dir(session.id)
    assert File.exists?(Path.join(dir, "workspace.tar.gz"))

    {:ok, coordinator} = Executions.lookup(session.owner_id)
    ref = Process.monitor(coordinator)
    :ok = Sessions.release(Repo.reload!(session))
    assert_receive {:pool_session_event, "session_ended", _}
    assert_receive {:DOWN, ^ref, :process, _, _}
    refute File.exists?(dir)
  end
end
