defmodule GoodFlowsWeb.Api.V1.PoolReportControllerTest do
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.FakeSprite
  alias GoodFlows.Pools.{Execs, Member, OwnerRPC, Session, Sessions, Transfers, TransferSemaphore}
  alias GoodFlows.Repo

  require Ecto.Query

  @moduletag :helper_binary

  setup :api_setup
  setup :set_mimic_global

  setup ctx do
    test_pid = self()
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    credential_fixture(ctx.account)
    project = project_fixture(ctx.account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "p", "max_members" => 2})
    member_fixture(pool)

    {:ok, session} =
      Sessions.create(ctx.account, project, "p", ctx.sk_key, %{
        "max_members" => 1,
        "acquire_timeout_ms" => 60_000
      })

    [member] = Sessions.members(session.id)

    exec =
      exec_fixture(session, member, %{
        status: "exited",
        exit_code: 0,
        collect_reports: true,
        reports: %{
          "files" => [
            %{"name" => "a.jsonl", "size" => 200_000, "too_large" => false},
            %{"name" => "big.jsonl", "size" => 40_000_000, "too_large" => true}
          ]
        }
      })

    root = FakeSprite.root!()
    reports = FakeSprite.path(root, member.name, "/tmp/gf-exec-#{exec.id}/reports")
    File.mkdir_p!(reports)
    bytes = :crypto.strong_rand_bytes(200_000)
    File.write!(Path.join(reports, "a.jsonl"), bytes)

    %{
      session: session,
      member: member,
      exec: exec,
      root: root,
      reports: reports,
      bytes: bytes,
      path: "/api/v1/pool-execs/#{exec.id}/reports/a.jsonl",
      test_pid: test_pid
    }
  end

  defp count_sends(test_pid) do
    helper = Transfers.helper_path()

    stub(GoodFlows.Spry.Sprites, :transfer, fn client,
                                               name,
                                               [^helper, "send" | _] = argv,
                                               owner,
                                               opts ->
      send(test_pid, :transfer_started)
      Mimic.call_original(GoodFlows.Spry.Sprites, :transfer, [client, name, argv, owner, opts])
    end)
  end

  test "downloads a verified report as NDJSON, accepting application/x-ndjson", ctx do
    FakeSprite.stub!(ctx.root)

    conn = ctx.sk_conn |> put_req_header("accept", "application/x-ndjson") |> get(ctx.path)
    assert response(conn, 200) == ctx.bytes
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/x-ndjson"
  end

  test "unlisted, too_large, and other-key requests", ctx do
    FakeSprite.stub!(ctx.root)

    assert ctx.sk_conn
           |> get("/api/v1/pool-execs/#{ctx.exec.id}/reports/nope.jsonl")
           |> json_response(404)

    assert ctx.sk_conn
           |> get("/api/v1/pool-execs/#{ctx.exec.id}/reports/big.jsonl")
           |> json_response(404)

    assert ctx.member_sk_conn |> get(ctx.path) |> json_response(403)
    assert ctx.other_conn |> get(ctx.path) |> json_response(404)
  end

  test "a report changed into a symlink or grown past 32 MiB is 404", ctx do
    FakeSprite.stub!(ctx.root)
    target = Path.join(ctx.reports, "a.jsonl")
    File.rm!(target)
    File.ln_s!("/etc/hostname", target)
    assert ctx.sk_conn |> get(ctx.path) |> json_response(404)

    File.rm!(target)
    {:ok, file} = :file.open(target, [:write, :raw])
    {:ok, _} = :file.position(file, 33_554_433)
    :ok = :file.truncate(file)
    :ok = :file.close(file)
    assert ctx.sk_conn |> get(ctx.path) |> json_response(404)
  end

  test "410 after the member starts another exec or is released", ctx do
    FakeSprite.stub!(ctx.root)
    later = exec_fixture(ctx.session, ctx.member, %{status: "exited"})
    assert ctx.sk_conn |> get(ctx.path) |> json_response(410)

    Repo.delete!(later)
    assert ctx.sk_conn |> get(ctx.path) |> response(200)

    :ok = Sessions.release_member(Repo.get!(Session, ctx.session.id), ctx.member.id)
    assert ctx.sk_conn |> get(ctx.path) |> json_response(410)
  end

  test "a request on a non-owner node streams the verified bytes over owner calls", ctx do
    FakeSprite.stub!(ctx.root)
    real_owner = ctx.session.owner_id
    [_node, boot, uuid] = String.split(real_owner, "|")
    _ = String.to_atom("owner@elsewhere")

    Repo.update_all(Ecto.Query.where(Session, id: ^ctx.session.id),
      set: [owner_id: "owner@elsewhere|#{boot}|#{uuid}"]
    )

    test_pid = self()

    Application.put_env(:good_flows, :pools_remote_call, fn node,
                                                            mod,
                                                            fun,
                                                            [_owner | rest],
                                                            _timeout ->
      send(test_pid, {:remote, node, hd(rest)})
      apply(mod, fun, [real_owner | rest])
    end)

    on_exit(fn -> Application.delete_env(:good_flows, :pools_remote_call) end)

    conn = get(ctx.sk_conn, ctx.path)
    assert response(conn, 200) == ctx.bytes
    assert_received {:remote, :owner@elsewhere, {:fetch_report, _, "a.jsonl"}}
    assert_received {:remote, :owner@elsewhere, {:read_report, _, "a.jsonl", 0, _}}
  end

  test "the response carries the verified SHA-256; a remote stream cut short aborts", ctx do
    FakeSprite.stub!(ctx.root)
    sha = Base.encode16(:crypto.hash(:sha256, ctx.bytes), case: :lower)

    conn = get(ctx.sk_conn, ctx.path)
    assert response(conn, 200) == ctx.bytes
    assert get_resp_header(conn, "x-content-sha256") == [sha]

    # From another node, the report is invalidated after the first chunk.
    real_owner = ctx.session.owner_id
    [_node, boot, uuid] = String.split(real_owner, "|")
    remote_owner = "owner@elsewhere|#{boot}|#{uuid}"
    _ = String.to_atom("owner@elsewhere")

    Repo.update_all(Ecto.Query.where(Session, id: ^ctx.session.id),
      set: [owner_id: remote_owner]
    )

    reads = :counters.new(1, [])

    Application.put_env(:good_flows, :pools_remote_call, fn _node,
                                                            mod,
                                                            fun,
                                                            [_owner, request | rest],
                                                            _timeout ->
      case request do
        {:read_report, _, _, _, _} ->
          :counters.add(reads, 1, 1)

          if :counters.get(reads, 1) > 1,
            do: {:error, :gone},
            else: apply(mod, fun, [real_owner, put_elem(request, 4, 1_000) | rest])

        _other ->
          apply(mod, fun, [real_owner, request | rest])
      end
    end)

    on_exit(fn -> Application.delete_env(:good_flows, :pools_remote_call) end)

    # The connection is dropped instead of ending the chunked body cleanly.
    assert catch_exit(get(ctx.sk_conn, ctx.path)) == {:shutdown, :report_invalidated}
  end

  test "concurrent requests share one transfer, and retries reuse the spool", ctx do
    FakeSprite.stub!(ctx.root, delay_ms: 200)
    count_sends(self())

    results =
      for _ <- 1..3 do
        Task.async(fn -> ctx.sk_conn |> get(ctx.path) |> response(200) end)
      end
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &(&1 == ctx.bytes))
    assert_received :transfer_started
    refute_received :transfer_started

    assert ctx.sk_conn |> get(ctx.path) |> response(200) == ctx.bytes
    refute_received :transfer_started
  end

  test "503 with Retry-After when not ready in time, then a retry succeeds", ctx do
    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

    Application.put_env(
      :good_flows,
      GoodFlows.Pools,
      Keyword.put(original, :report_fetch_timeout_ms, 100)
    )

    FakeSprite.stub!(ctx.root, delay_ms: 500)
    count_sends(self())

    conn = get(ctx.sk_conn, ctx.path)
    assert json_response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["1"]

    Application.put_env(
      :good_flows,
      GoodFlows.Pools,
      Keyword.put(original, :report_fetch_timeout_ms, 5_000)
    )

    assert ctx.sk_conn |> get(ctx.path) |> response(200) == ctx.bytes
    # The retry joined the transfer the first request started.
    assert_received :transfer_started
    refute_received :transfer_started
  end

  test "503 when transfer capacity is saturated or the transfer fails", ctx do
    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

    Application.put_env(
      :good_flows,
      GoodFlows.Pools,
      Keyword.merge(original, transfer_concurrency: 1, report_fetch_timeout_ms: 200)
    )

    FakeSprite.stub!(ctx.root)
    {:ok, permit} = TransferSemaphore.acquire()
    assert ctx.sk_conn |> get(ctx.path) |> json_response(503)
    TransferSemaphore.release(permit)

    Application.put_env(
      :good_flows,
      GoodFlows.Pools,
      Keyword.put(original, :report_fetch_timeout_ms, 2_000)
    )

    FakeSprite.stub!(ctx.root, missing_helper: true)
    conn = get(ctx.sk_conn, ctx.path)
    assert json_response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["1"]
  end

  test "a download racing the next exec admission is invalidated", ctx do
    FakeSprite.stub!(ctx.root, delay_ms: 300)

    Repo.update_all(Ecto.Query.where(Member, id: ^ctx.member.id),
      set: [workspace_ready_generation: ctx.member.lease_generation]
    )

    task = Task.async(fn -> ctx.sk_conn |> get(ctx.path) end)
    Process.sleep(50)

    GoodFlows.FakeExec.stub!(self())

    {:ok, request} =
      Execs.validate_request(%{"member_id" => ctx.member.id, "command" => "next"})

    assert {:ok, _} = OwnerRPC.call(ctx.session.owner_id, {:start_exec, request})

    conn = Task.await(task, 5_000)
    assert conn.status == 410
  end
end
