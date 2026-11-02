defmodule GoodFlowsWeb.Api.V1.PoolSessionControllerTest do
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TarFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Pools.{Config, OwnerRPC, Session, Spool}
  alias GoodFlows.Spry.Executions
  alias GoodFlowsWeb.{ApiSpec, GreedyBodyAdapter}
  alias GoodFlowsWeb.Plugs.BodyParsers
  alias Plug.Adapters.Test.Conn, as: TestConn

  require Ecto.Query

  setup :api_setup
  setup :set_mimic_global

  setup ctx do
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    credential_fixture(ctx.account)
    project = project_fixture(ctx.account, %{"slug" => "app"})
    pool = pool_fixture(project, %{"slug" => "rust-ci", "max_members" => 4})
    %{project: project, pool: pool}
  end

  @create_path "/api/v1/projects/app/pools/rust-ci/sessions"
  @body %{"max_members" => 4, "acquire_timeout_ms" => 120_000}

  defp create!(conn) do
    conn |> post(@create_path, @body) |> json_response(201) |> Map.fetch!("data")
  end

  describe "POST /projects/:project/pools/:pool/sessions" do
    test "201 waiting with the channel topic", ctx do
      body =
        ctx.sk_conn |> post(@create_path, Map.put(@body, "label", "ci")) |> json_response(201)

      assert_schema(body, "PoolSessionResponse", ApiSpec.spec())

      data = body["data"]
      assert data["status"] == "waiting"
      assert data["topic"] == "pool_session:#{data["id"]}"
      assert data["pool"] == "rust-ci"
      assert data["project"] == "app"
      assert data["label"] == "ci"
      assert data["end_reason"] == nil
      refute Map.has_key?(data, "owner_id")
    end

    test "422 for too many members or unknown keys; 404 for a missing pool; 403 for pk", ctx do
      body =
        ctx.sk_conn |> post(@create_path, %{@body | "max_members" => 5}) |> json_response(422)

      assert body["errors"]["max_members"]

      body =
        ctx.sk_conn |> post(@create_path, Map.put(@body, "priority", 9)) |> json_response(422)

      assert body["errors"]["priority"]

      assert ctx.sk_conn
             |> post("/api/v1/projects/app/pools/nope/sessions", @body)
             |> json_response(404)

      assert ctx.other_conn |> post(@create_path, @body) |> json_response(404)
      assert ctx.pk_conn |> post(@create_path, @body) |> json_response(403)
      assert GoodFlows.Repo.aggregate(Session, :count) == 0
    end

    test "422 without a credential", ctx do
      GoodFlows.Spry.delete_credential(ctx.account)
      body = ctx.sk_conn |> post(@create_path, @body) |> json_response(422)
      assert body["errors"]["detail"] =~ "Sprites credential"
    end
  end

  describe "GET and DELETE /pool-sessions/:id" do
    test "any key of the account reads; only the creating key releases", ctx do
      session = create!(ctx.sk_conn)
      path = "/api/v1/pool-sessions/#{session["id"]}"

      body = ctx.pk_conn |> get(path) |> json_response(200)
      assert_schema(body, "PoolSessionResponse", ApiSpec.spec())
      assert ctx.other_conn |> get(path) |> json_response(404)

      assert ctx.member_sk_conn |> delete(path) |> json_response(403)
      assert ctx.other_conn |> delete(path) |> json_response(404)

      assert ctx.sk_conn |> get(path) |> json_response(200) |> get_in(["data", "status"]) ==
               "waiting"

      assert ctx.sk_conn |> delete(path) |> response(204)

      assert ctx.sk_conn |> get(path) |> json_response(200) |> get_in(["data", "status"]) ==
               "released"

      # Repeat release: 204, nothing changes.
      assert ctx.sk_conn |> delete(path) |> response(204)
    end

    test "the response is free of env, commands, and output", ctx do
      session = create!(ctx.sk_conn)
      body = ctx.sk_conn |> get("/api/v1/pool-sessions/#{session["id"]}") |> json_response(200)

      for key <- ~w(env command argv output outputs owner_id credential_fingerprint) do
        refute Map.has_key?(body["data"], key)
      end
    end
  end

  describe "PUT /pool-sessions/:id/workspace" do
    setup ctx do
      session = create!(ctx.sk_conn)
      %{session: session, path: "/api/v1/pool-sessions/#{session["id"]}/workspace"}
    end

    defp gz(conn), do: put_req_header(conn, "content-type", "application/gzip")

    defp archive, do: tar_gz([{:dir, "src"}, {:file, "src/a.txt", "hello"}])

    test "an upload on another node streams through bounded owner calls", ctx do
      real_owner = GoodFlows.Repo.get!(Session, ctx.session["id"]).owner_id
      [_node, boot, uuid] = String.split(real_owner, "|")
      _ = String.to_atom("owner@elsewhere")

      session_id = ctx.session["id"]

      GoodFlows.Repo.update_all(Ecto.Query.where(Session, id: ^session_id),
        set: [owner_id: "owner@elsewhere|#{boot}|#{uuid}"]
      )

      test_pid = self()

      Application.put_env(:good_flows, :pools_remote_call, fn node,
                                                              mod,
                                                              fun,
                                                              [_owner, request | rest],
                                                              _timeout ->
        send(test_pid, {:remote, node, elem(request, 0)})

        # The coordinator records the upload fenced on its own owner id:
        # point the row back at it once the controller has routed.
        if elem(request, 0) == :upload_finish do
          GoodFlows.Repo.update_all(Ecto.Query.where(Session, id: ^session_id),
            set: [owner_id: real_owner]
          )
        end

        apply(mod, fun, [real_owner, request | rest])
      end)

      on_exit(fn -> Application.delete_env(:good_flows, :pools_remote_call) end)

      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)

      assert_received {:remote, :owner@elsewhere, :upload_begin}
      assert_received {:remote, :owner@elsewhere, :upload_chunk}
      assert_received {:remote, :owner@elsewhere, :upload_finish}

      assert %Session{workspace_uploaded_at: %DateTime{}} =
               GoodFlows.Repo.get!(Session, ctx.session["id"])
    end

    test "204 once, then 409", ctx do
      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)

      assert %Session{workspace_uploaded_at: %DateTime{}, workspace_bytes: bytes} =
               GoodFlows.Repo.get!(Session, ctx.session["id"])

      assert bytes == byte_size(archive())
      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> json_response(409)

      body =
        ctx.sk_conn |> get("/api/v1/pool-sessions/#{ctx.session["id"]}") |> json_response(200)

      assert body["data"]["workspace_uploaded"]
    end

    test "content type and encoding", ctx do
      conn =
        ctx.sk_conn
        |> put_req_header("content-type", "application/json")
        |> put(ctx.path, archive())

      assert json_response(conn, 415)["errors"]["detail"] =~ "application/gzip"

      conn =
        ctx.sk_conn
        |> gz()
        |> put_req_header("content-encoding", "gzip")
        |> put(ctx.path, archive())

      assert json_response(conn, 415)

      conn =
        ctx.sk_conn
        |> gz()
        |> put_req_header("content-encoding", "identity")
        |> put(ctx.path, archive())

      assert response(conn, 204)
    end

    test "oversized bodies are 413, declared or streamed, and stay retryable", ctx do
      limit = Config.workspace_max_bytes()

      conn =
        ctx.sk_conn
        |> gz()
        |> put_req_header("content-length", "#{limit + 1}")
        |> put(ctx.path, archive())

      assert json_response(conn, 413)

      conn = ctx.sk_conn |> gz() |> put(ctx.path, :binary.copy(<<0>>, limit + 1))
      assert json_response(conn, 413)
      assert Spool.reserved_bytes() == 0

      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)
    end

    test "corrupt and non-confined archives are 422 and a corrected upload is accepted", ctx do
      body =
        ctx.sk_conn
        |> gz()
        |> put(ctx.path, tar_gz([{:file, "../etc/passwd", "x"}]))
        |> json_response(422)

      assert [message] = body["errors"]["body"]
      assert message =~ ".."

      assert ctx.sk_conn |> gz() |> put(ctx.path, "garbage") |> json_response(422)

      big = tar_gz(for i <- 1..2, do: {:file, "f#{i}", ""})
      original = Application.get_env(:good_flows, GoodFlows.Pools)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.put(original, :workspace_max_entries, 1)
      )

      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
      assert ctx.sk_conn |> gz() |> put(ctx.path, big) |> json_response(413)
      Application.put_env(:good_flows, GoodFlows.Pools, original)

      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)
    end

    test "an exhausted spool budget is 503 with Retry-After", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.put(original, :spool_max_bytes, 10)
      )

      conn = ctx.sk_conn |> gz() |> put(ctx.path, archive())
      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["1"]
    end

    test "a second concurrent upload from the same account is 503", ctx do
      {:ok, ref} = Spool.reserve(ctx.account.id, 1)
      conn = ctx.sk_conn |> gz() |> put(ctx.path, archive())
      assert json_response(conn, 503)
      Spool.release(ref)
      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)
    end

    test "a read past the deadline is 408 and releases the reservation", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.put(original, :workspace_read_timeout_ms, 50)
      )

      conn =
        ctx.sk_conn
        |> gz()
        |> Map.put(:method, "PUT")
        |> Map.put(:request_path, ctx.path)
        |> Map.put(:path_info, String.split(ctx.path, "/", trim: true))
        |> TestConn.conn(:put, ctx.path, archive())
        |> GreedyBodyAdapter.wrap(trickle: {10, 30})
        |> GoodFlowsWeb.Endpoint.call([])

      assert json_response(conn, 408)
      assert Spool.reserved_bytes() == 0

      Application.put_env(:good_flows, GoodFlows.Pools, original)
      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)
    end

    # An upload begun on the session's coordinator by `uploader`, with one
    # chunk spooled: a workspace upload in the middle of its body.
    defp begin_upload(ctx, uploader) do
      owner = GoodFlows.Repo.get!(Session, ctx.session["id"]).owner_id
      {:ok, ref} = OwnerRPC.call(owner, {:upload_begin, uploader})
      :ok = OwnerRPC.call(owner, {:upload_chunk, ref, "partial"})
      {owner, ref}
    end

    defp coordinator_settled(owner) do
      {:ok, pid} = Executions.lookup(owner)
      _ = :sys.get_state(pid)
      :ok
    end

    test "a second upload while one is streaming is 409 upload_in_progress", ctx do
      uploader = spawn(fn -> Process.sleep(:infinity) end)
      {owner, ref} = begin_upload(ctx, uploader)

      body = ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> json_response(409)
      assert body["errors"]["detail"] =~ "in progress"

      :ok = OwnerRPC.call(owner, {:upload_abort, ref})
      Process.exit(uploader, :kill)
    end

    test "an uploader that dies mid-body releases its reservation; a retry is accepted", ctx do
      uploader = spawn(fn -> Process.sleep(:infinity) end)
      {owner, _ref} = begin_upload(ctx, uploader)
      assert Spool.reserved_bytes() > 0

      down = Process.monitor(uploader)
      Process.exit(uploader, :kill)
      assert_receive {:DOWN, ^down, :process, _, :killed}
      :ok = coordinator_settled(owner)
      assert Spool.reserved_bytes() == 0

      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)
    end

    test "an owner unavailable mid-upload is 503 with Retry-After and releases the reservation",
         ctx do
      # The controller calls with the default timeout (call/2).
      stub(OwnerRPC, :call, fn
        _owner, {:upload_chunk, _ref, _data} -> {:error, :owner_unavailable}
        owner, request -> call_original(OwnerRPC, :call, [owner, request])
      end)

      conn = ctx.sk_conn |> gz() |> put(ctx.path, archive())
      assert json_response(conn, 503)["errors"]["detail"] =~ "unavailable"
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert Spool.reserved_bytes() == 0
      assert GoodFlows.Repo.get!(Session, ctx.session["id"]).workspace_uploaded_at == nil

      stub(OwnerRPC, :call, &call_original(OwnerRPC, :call, [&1, &2]))
      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> response(204)
    end

    test "another key is 403, another account 404, an ended session 409", ctx do
      assert ctx.member_sk_conn |> gz() |> put(ctx.path, archive()) |> json_response(403)
      assert ctx.other_conn |> gz() |> put(ctx.path, archive()) |> json_response(404)
      assert ctx.pk_conn |> gz() |> put(ctx.path, archive()) |> json_response(403)

      ctx.sk_conn |> delete("/api/v1/pool-sessions/#{ctx.session["id"]}") |> response(204)
      assert ctx.sk_conn |> gz() |> put(ctx.path, archive()) |> json_response(409)
    end

    test "the route bypasses body parsing and Sentry body capture", ctx do
      conn = Phoenix.ConnTest.build_conn(:put, ctx.path)
      assert GoodFlowsWeb.SentryScrubber.scrub(conn) == %{}
      assert BodyParsers.raw_body_route?(conn)

      refute BodyParsers.raw_body_route?(~w(api v1 pool-sessions x workspace extra))
    end
  end

  test "operations appear in the OpenAPI document", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")

    assert paths["/api/v1/projects/{project}/pools/{pool}/sessions"]["post"]["responses"]["415"]
    assert paths["/api/v1/pool-sessions/{id}"]["get"]
    assert paths["/api/v1/pool-sessions/{id}"]["delete"]

    workspace = paths["/api/v1/pool-sessions/{id}/workspace"]["put"]

    assert Enum.sort(Map.keys(workspace["responses"])) ==
             ~w(204 400 401 403 404 408 409 413 415 422 503)

    assert paths["/api/v1/pool-execs/{id}/reports/{name}"]["get"]["responses"]["410"]
  end
end
