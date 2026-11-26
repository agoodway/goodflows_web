defmodule GoodFlowsWeb.Api.V1.WorkflowRunControllerTest do
  use GoodFlowsWeb.ConnCase, async: true
  use Mimic

  setup :verify_on_exit!

  import Ecto.Query
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures
  import GoodFlows.WorkflowRunFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.{Accounts, Repo}
  alias GoodFlows.JsonDocument
  alias GoodFlows.WorkflowRuns.{Run, Store}
  alias GoodFlowsWeb.ApiSpec
  alias GoodFlowsWeb.Plugs.WorkflowRunBody

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp upload(conn, slug, body, content_type \\ "application/json") do
    conn
    |> put_req_header("content-type", content_type)
    |> post("/api/v1/projects/#{slug}/workflow-runs", body)
  end

  defp show(conn, slug, run_id) do
    get(conn, "/api/v1/projects/#{slug}/workflow-runs/#{run_id}")
  end

  defp list(conn, slug, query \\ "") do
    get(conn, "/api/v1/projects/#{slug}/workflow-runs#{query}")
  end

  defp body_unread?(conn, body), do: match?({:ok, ^body, _conn}, Plug.Conn.read_body(conn))

  defp run_count, do: Repo.aggregate(Run, :count)

  defp spec, do: ApiSpec.spec()

  defp reorder_json(json) do
    {:ok, decoded} = JsonDocument.decode(json)
    Jason.encode!(reverse_keys(decoded))
  end

  defp reverse_keys(%Jason.OrderedObject{values: pairs}) do
    pairs
    |> Enum.reverse()
    |> Enum.map(fn {key, value} -> {key, reverse_keys(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp reverse_keys(list) when is_list(list), do: Enum.map(list, &reverse_keys/1)
  defp reverse_keys(other), do: other

  defp postgres_error(pg_code, extra) do
    %Postgrex.Error{
      postgres:
        Map.merge(%{code: nil, pg_code: pg_code, severity: "ERROR", message: "boom"}, extra)
    }
  end

  @thread "https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"
  @threads "https://ampcode.com/threads/"

  defp with_links(links, attrs \\ %{}),
    do: minimal() |> Map.merge(attrs) |> Map.put("links", links)

  defp run_ids(conn, slug, query) do
    page = conn |> list(slug, query) |> json_response(200)
    assert_schema(page, "WorkflowRunListResponse", spec())
    Enum.map(page["data"], & &1["run_id"])
  end

  defp user_of(api_key) do
    api_key |> Repo.preload(account_user: :user) |> then(& &1.account_user.user)
  end

  describe "upload" do
    test "a new run is 201 and an exact retry with reordered keys is 200", ctx do
      body = json("full")
      created = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
      assert_schema(created, "WorkflowRunAcknowledgement", spec())

      assert %{
               "id" => id,
               "run_id" => "44444444-4444-4444-8444-444444444444",
               "duplicate" => false
             } = created["data"]

      assert Map.keys(created["data"]) |> Enum.sort() == ~w(duplicate id run_id)
      refute Map.has_key?(created["data"], "document")
      refute Map.has_key?(created, "results")

      retry =
        ctx.sk_conn |> upload(ctx.project.slug, reorder_json(body)) |> json_response(200)

      assert_schema(retry, "WorkflowRunAcknowledgement", spec())
      assert retry["data"] == %{created["data"] | "duplicate" => true}

      stored = Repo.get!(Run, id)
      assert stored.project_id == ctx.project.id
      assert stored.account_id == ctx.account.id
      assert stored.api_key_id == ctx.sk_key.id
      assert run_count() == 1
    end

    test "minimal, cancelled, failed and both golden fixtures are stored", ctx do
      for body <- [
            json("minimal"),
            json("cancelled-by-signal"),
            json("failed"),
            golden_json("parent-default"),
            golden_json("child-suite")
          ] do
        assert ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
      end

      assert run_count() == 5
    end

    test "a conflicting outcome is 409 without the stored id or document", ctx do
      %{"data" => %{"id" => id}} =
        ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(201)

      changed = minimal() |> Map.put("outcome", "cancelled") |> Jason.encode!()
      body = ctx.sk_conn |> upload(ctx.project.slug, changed) |> json_response(409)

      assert_schema(body, "ConflictResponse", spec())
      refute inspect(body) =~ id
      refute inspect(body) =~ "results"
      assert Repo.get!(Run, id).outcome == "passed"
      assert run_count() == 1
    end

    test "reordered results are 409 and the stored row is unchanged", ctx do
      %{"data" => %{"id" => id}} =
        ctx.sk_conn |> upload(ctx.project.slug, json("full")) |> json_response(201)

      stored = Repo.get!(Run, id)
      swapped = full() |> Map.update!("results", &Enum.reverse/1) |> Jason.encode!()
      assert ctx.sk_conn |> upload(ctx.project.slug, swapped) |> json_response(409)
      assert Repo.get!(Run, id).payload == stored.payload
    end

    test "the same run id in another project is a separate row", ctx do
      other = project_fixture(ctx.account)
      body = json("minimal")

      mine = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
      theirs = ctx.sk_conn |> upload(other.slug, body) |> json_response(201)

      refute theirs["data"]["id"] == mine["data"]["id"]
      assert theirs["data"]["duplicate"] == false
      assert run_count() == 2
    end

    test "charset=utf-8 is accepted", ctx do
      assert ctx.sk_conn
             |> upload(ctx.project.slug, json("minimal"), "application/json; charset=UTF-8")
             |> json_response(201)
    end
  end

  describe "authentication and project" do
    test "missing, expired and revoked keys are 401 without reading the body", ctx do
      body = json("minimal")
      ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)

      account_user = Accounts.get_account_user(user_of(ctx.sk_key), ctx.account)

      {expired, expired_token} =
        GoodFlows.AccountsFixtures.api_key_fixture(account_user, %{type: :private})

      Repo.update_all(from(key in Accounts.ApiKey, where: key.id == ^expired.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60)]
      )

      {revoked, revoked_token} =
        GoodFlows.AccountsFixtures.api_key_fixture(account_user, %{type: :private})

      {:ok, _} = Accounts.revoke_api_key(revoked)

      conns = [
        build_conn() |> put_req_header("accept", "application/json"),
        api_conn(expired_token),
        api_conn(revoked_token),
        api_conn("sk_not_a_real_key")
      ]

      for conn <- conns do
        conn = upload(conn, ctx.project.slug, body)
        assert json_response(conn, 401)
        assert body_unread?(conn, body)
      end

      assert run_count() == 1
    end

    test "a public key is 403 before the slug is validated, including GoodCases", ctx do
      body = json("minimal")

      for slug <- [ctx.project.slug, "missing", "GoodCases"] do
        conn = upload(ctx.pk_conn, slug, body)
        assert json_response(conn, 403)
        assert body_unread?(conn, body)
      end

      assert run_count() == 0
    end

    test "an unknown or other-account slug is 404 without reading the body", ctx do
      other = project_fixture(ctx.other_account)
      body = json("minimal")

      for slug <- ["missing", other.slug] do
        conn = upload(ctx.sk_conn, slug, body)
        assert_schema(json_response(conn, 404), "ErrorResponse", spec())
        assert body_unread?(conn, body)
      end

      assert run_count() == 0
    end

    test "an invalid slug is 422 on project without reading the body", ctx do
      body = json("minimal")
      conn = upload(ctx.sk_conn, "GoodCases", body)
      response = json_response(conn, 422)

      assert_schema(response, "ValidationErrorResponse", spec())
      assert response["errors"]["project"]
      assert body_unread?(conn, body)
      assert run_count() == 0
    end

    test "an unauthenticated oversized upload is 401 without reading", %{project: project} do
      body = String.duplicate(" ", WorkflowRunBody.max_body_bytes() + 10)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> upload(project.slug, body)

      assert json_response(conn, 401)
      assert body_unread?(conn, body)
    end
  end

  describe "body handling" do
    test "Accept text/plain is 406 before the body is read", ctx do
      body = json("minimal")

      # `:api` rejects the Accept header before the body plug. The test
      # adapter surfaces that as NotAcceptableError, which a server renders
      # as 406.
      assert_error_sent 406, fn ->
        ctx.sk_conn
        |> put_req_header("accept", "text/plain")
        |> upload(ctx.project.slug, body)
      end

      assert run_count() == 0
    end

    test "a declared or streamed body over the limit is 413 and stores nothing", ctx do
      body = json("minimal")
      limit = WorkflowRunBody.max_body_bytes()

      declared =
        ctx.sk_conn
        |> put_req_header("content-length", Integer.to_string(limit + 1))
        |> upload(ctx.project.slug, body)

      assert_schema(json_response(declared, 413), "ErrorResponse", spec())
      assert body_unread?(declared, body)

      streamed = String.duplicate(" ", limit + 1)
      assert ctx.sk_conn |> upload(ctx.project.slug, streamed) |> json_response(413)

      understated =
        ctx.sk_conn
        |> put_req_header("content-length", "10")
        |> upload(ctx.project.slug, streamed)

      assert json_response(understated, 413)
      assert run_count() == 0
    end

    test "a body exactly at the limit is stored", ctx do
      json = json("minimal")
      limit = WorkflowRunBody.max_body_bytes()
      padded = json <> String.duplicate(" ", limit - byte_size(json))

      assert ctx.sk_conn |> upload(ctx.project.slug, padded) |> json_response(201)
      assert ctx.sk_conn |> upload(ctx.project.slug, padded <> " ") |> json_response(413)
    end

    test "malformed JSON is 400 and does not echo the body", ctx do
      sentinel = "SENTINEL-malformed-55e1"

      body =
        ctx.sk_conn
        |> upload(ctx.project.slug, ~s({"workflow":"#{sentinel}"))
        |> json_response(400)

      assert_schema(body, "ErrorResponse", spec())
      refute inspect(body) =~ sentinel
      assert run_count() == 0
    end

    test "non-JSON content types and gzip are 415", ctx do
      body = json("minimal")

      conn = upload(ctx.sk_conn, ctx.project.slug, body, "text/plain")
      assert_schema(json_response(conn, 415), "ErrorResponse", spec())
      assert body_unread?(conn, body)

      conn =
        ctx.sk_conn
        |> put_req_header("content-encoding", "gzip")
        |> upload(ctx.project.slug, body)

      assert json_response(conn, 415)
      assert body_unread?(conn, body)
      assert run_count() == 0
    end

    test "duplicate keys, NUL, depth, non-integers and huge integers are 422 and store nothing",
         ctx do
      duplicate = ~s({"outcome":"passed","outcome":"failed"})
      body = ctx.sk_conn |> upload(ctx.project.slug, duplicate) |> json_response(422)
      assert body["errors"]["body"] == ["has a duplicate key"]

      nul = ~s({"workflow":"ci\\u0000"})
      body = ctx.sk_conn |> upload(ctx.project.slug, nul) |> json_response(422)
      assert body["errors"]["workflow"] == ["must not contain NUL characters"]

      deep = String.duplicate("[", 9) <> String.duplicate("]", 9)
      body = ctx.sk_conn |> upload(ctx.project.slug, deep) |> json_response(422)
      assert body["errors"] == %{"body" => ["is nested too deeply"]}

      fraction =
        String.replace(json("minimal"), "\"duration_ms\": 0", "\"duration_ms\": 1.0",
          global: false
        )

      body = ctx.sk_conn |> upload(ctx.project.slug, fraction) |> json_response(422)
      assert body["errors"]["duration_ms"]

      huge =
        String.replace(json("minimal"), "\"duration_ms\": 0", "\"duration_ms\": 9007199254740992")

      body = ctx.sk_conn |> upload(ctx.project.slug, huge) |> json_response(422)
      assert body["errors"]["duration_ms"] == ["is out of range"]
      assert run_count() == 0
    end

    test "a database outage is 503 with Retry-After", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise DBConnection.ConnectionError, "connection refused"
      end)

      conn = upload(ctx.sk_conn, ctx.project.slug, json("minimal"))
      assert_schema(json_response(conn, 503), "ErrorResponse", spec())
      assert get_resp_header(conn, "retry-after") == ["1"]
      refute json_response(conn, 503)["data"]
      assert run_count() == 0
    end

    test "a project foreign key is 404 and any other foreign key is 503", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise postgres_error("23503", %{constraint: "workflow_runs_project_id_fkey"})
      end)

      assert ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(404)

      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise postgres_error("23503", %{constraint: "workflow_runs_api_key_id_fkey"})
      end)

      conn = upload(ctx.sk_conn, ctx.project.slug, json("minimal"))
      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["1"]
    end

    test "a lost commit is 503 and the exact retry is 200", ctx do
      # The insert commits with its transaction; the reply to COMMIT is lost.
      expect(Store, :transaction, fn fun, opts ->
        _committed = call_original(Store, :transaction, [fun, opts])
        raise DBConnection.ConnectionError, "connection closed before the reply"
      end)

      assert ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(503)

      retry = ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(200)
      assert retry["data"]["duplicate"] == true
      assert run_count() == 1
    end
  end

  describe "list and show" do
    test "an unacceptable Accept header on GET list is 406", ctx do
      # `:api` rejects the Accept header before the action. The test adapter
      # surfaces that as NotAcceptableError, which a server renders as 406.
      assert_error_sent 406, fn ->
        ctx.sk_conn
        |> put_req_header("accept", "text/plain")
        |> list(ctx.project.slug)
      end
    end

    test "lists newest started_at first, pages, and lets a public key list", ctx do
      older = minimal() |> Map.put("started_at", "2026-11-05T12:00:00Z") |> Jason.encode!()

      newer =
        minimal()
        |> Map.merge(%{
          "run_id" => "ffffffff-ffff-4fff-8fff-ffffffffffff",
          "started_at" => "2026-11-06T12:00:00Z"
        })
        |> Jason.encode!()

      middle =
        minimal()
        |> Map.merge(%{
          "run_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          "started_at" => "2026-11-05T18:00:00Z"
        })
        |> Jason.encode!()

      ctx.sk_conn |> upload(ctx.project.slug, older) |> json_response(201)
      ctx.sk_conn |> upload(ctx.project.slug, newer) |> json_response(201)
      ctx.sk_conn |> upload(ctx.project.slug, middle) |> json_response(201)

      page = ctx.pk_conn |> list(ctx.project.slug, "?limit=2") |> json_response(200)
      assert_schema(page, "WorkflowRunListResponse", spec())

      assert Enum.map(page["data"], & &1["run_id"]) == [
               "ffffffff-ffff-4fff-8fff-ffffffffffff",
               "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
             ]

      refute Enum.any?(page["data"], &Map.has_key?(&1, "results"))
      assert page["next_cursor"]

      next =
        ctx.sk_conn
        |> list(ctx.project.slug, "?limit=2&cursor=#{URI.encode_www_form(page["next_cursor"])}")
        |> json_response(200)

      assert Enum.map(next["data"], & &1["run_id"]) == ["11111111-1111-4111-8111-111111111111"]
      assert next["next_cursor"] == nil
    end

    test "summaries name the failed and timed-out jobs, for sk_ and pk_ keys", ctx do
      result = fn name, status ->
        %{
          "name" => name,
          "status" => status,
          "exit_code" => if(status == "passed", do: 0, else: 1),
          "command" => "run #{name}",
          "error" => nil,
          "duration_ms" => 1,
          "started" => true,
          "blocked_ms" => 0,
          "queued_ms" => 0
        }
      end

      failed =
        Map.merge(minimal(), %{
          "run_id" => "ffffffff-ffff-4fff-8fff-ffffffffffff",
          "started_at" => "2026-11-06T12:00:00Z",
          "outcome" => "failed",
          "results" => [
            result.("compile", "passed"),
            result.("test", "failed"),
            result.("lint", "timed_out"),
            result.("deploy", "cancelled")
          ]
        })

      passed =
        Map.put(minimal(), "results", [result.("compile", "passed"), result.("lint", "skipped")])

      for document <- [failed, passed] do
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)
      end

      for conn <- [ctx.sk_conn, ctx.pk_conn] do
        page = conn |> list(ctx.project.slug) |> json_response(200)
        assert_schema(page, "WorkflowRunListResponse", spec())
        assert Enum.map(page["data"], & &1["failed_jobs"]) == [["test", "lint"], []]
      end
    end

    test "equal start times order by run_id descending", ctx do
      low =
        minimal() |> Map.put("run_id", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") |> Jason.encode!()

      high =
        minimal() |> Map.put("run_id", "ffffffff-ffff-4fff-8fff-ffffffffffff") |> Jason.encode!()

      ctx.sk_conn |> upload(ctx.project.slug, low) |> json_response(201)
      ctx.sk_conn |> upload(ctx.project.slug, high) |> json_response(201)

      page = ctx.sk_conn |> list(ctx.project.slug) |> json_response(200)

      assert Enum.map(page["data"], & &1["run_id"]) == [
               "ffffffff-ffff-4fff-8fff-ffffffffffff",
               "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
             ]
    end

    test "a run inserted onto the first page is neither repeated nor skipped", ctx do
      for {id, at} <- [
            {"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "2026-11-05T12:00:01Z"},
            {"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "2026-11-05T12:00:02Z"},
            {"ffffffff-ffff-4fff-8fff-ffffffffffff", "2026-11-05T12:00:03Z"}
          ] do
        body = minimal() |> Map.merge(%{"run_id" => id, "started_at" => at}) |> Jason.encode!()
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
      end

      page = ctx.sk_conn |> list(ctx.project.slug, "?limit=2") |> json_response(200)

      extra =
        minimal()
        |> Map.merge(%{
          "run_id" => "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          "started_at" => "2026-11-05T12:00:03Z"
        })
        |> Jason.encode!()

      ctx.sk_conn |> upload(ctx.project.slug, extra) |> json_response(201)

      next =
        ctx.sk_conn
        |> list(ctx.project.slug, "?limit=2&cursor=#{URI.encode_www_form(page["next_cursor"])}")
        |> json_response(200)

      assert Enum.map(next["data"], & &1["run_id"]) == ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
    end

    test "summaries rebuild source and host, and filters combine", ctx do
      bare = json("minimal")

      sourced =
        minimal()
        |> Map.merge(%{
          "run_id" => "ffffffff-ffff-4fff-8fff-ffffffffffff",
          "started_at" => "2026-11-06T12:00:00Z",
          "environment" => "ci",
          "workflow" => "other",
          "source" => %{"commit" => String.duplicate("ab", 32)}
        })
        |> Jason.encode!()

      ctx.sk_conn |> upload(ctx.project.slug, bare) |> json_response(201)
      ctx.sk_conn |> upload(ctx.project.slug, sourced) |> json_response(201)

      page = ctx.sk_conn |> list(ctx.project.slug) |> json_response(200)
      [with_source, without_source] = page["data"]

      assert without_source["environment"] == nil
      assert without_source["source"] == nil
      assert with_source["environment"] == "ci"
      assert with_source["source"] == %{"commit" => String.duplicate("ab", 32)}
      refute Map.has_key?(with_source["source"], "dirty")
      assert with_source["host"] == %{"os" => "linux", "arch" => "x86_64", "logical_cpus" => 1}
      assert with_source["started_at"] == "2026-11-06T12:00:00Z"

      graph = minimal()["graph_sha256"]

      filtered =
        ctx.sk_conn
        |> list(ctx.project.slug, "?workflow=ci&graph_sha256=#{graph}")
        |> json_response(200)

      assert Enum.map(filtered["data"], & &1["run_id"]) == [minimal()["run_id"]]

      ignored = ctx.sk_conn |> list(ctx.project.slug, "?color=blue") |> json_response(200)
      assert length(ignored["data"]) == 2
    end

    test "branch and event filter on source.branch and ci.event", ctx do
      run = fn run_id, started_at, source, ci ->
        minimal()
        |> Map.merge(%{"run_id" => run_id, "started_at" => started_at})
        |> then(&if(source, do: Map.put(&1, "source", source), else: &1))
        |> then(&if(ci, do: Map.put(&1, "ci", ci), else: &1))
        |> Jason.encode!()
      end

      commit = String.duplicate("a", 40)
      push = %{"provider" => "github_actions", "event" => "push"}
      pr = %{"provider" => "github_actions", "event" => "pull_request", "pull_request" => 7}

      runs = [
        {"11111111-0000-4000-8000-000000000001", %{"commit" => commit, "branch" => "main"}, push},
        {"11111111-0000-4000-8000-000000000002", %{"commit" => commit, "branch" => "feat/x"},
         push},
        {"11111111-0000-4000-8000-000000000003", %{"commit" => commit}, pr},
        {"11111111-0000-4000-8000-000000000004", %{"commit" => commit, "branch" => "main"},
         %{"provider" => "github_actions"}},
        {"11111111-0000-4000-8000-000000000005", nil, nil}
      ]

      for {{run_id, source, ci}, day} <- Enum.with_index(runs, 1) do
        body = run.(run_id, "2026-11-0#{day}T12:00:00Z", source, ci)
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
      end

      ids = fn query ->
        ctx.sk_conn
        |> list(ctx.project.slug, query)
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(&String.last(&1["run_id"]))
      end

      assert ids.("?branch=main") == ~w(4 1)
      assert ids.("?branch=feat%2Fx") == ~w(2)
      assert ids.("?event=push") == ~w(2 1)
      assert ids.("?event=pull_request") == ~w(3)
      assert ids.("?branch=main&event=push") == ~w(1)
      assert ids.("?branch=Main") == []
      assert ids.("?branch=main&event=push&limit=1&workflow=ci") == ~w(1)

      page = ctx.sk_conn |> list(ctx.project.slug, "?branch=main") |> json_response(200)
      assert_schema(page, "WorkflowRunListResponse", spec())
      [latest, first] = page["data"]
      assert latest["source"] == %{"commit" => commit, "branch" => "main"}
      assert latest["ci"] == %{"provider" => "github_actions"}
      assert first["ci"] == push

      [none] =
        ctx.sk_conn
        |> list(ctx.project.slug, "?limit=1")
        |> json_response(200)
        |> Map.fetch!("data")

      assert none["source"] == nil
      assert none["ci"] == nil
    end

    test "invalid filters and cursors are 422 on that parameter", ctx do
      for {query, field} <- [
            {"?outcome=green", "outcome"},
            {"?workflow=#{String.duplicate("a", 65)}", "workflow"},
            {"?environment=%20%20%20", "environment"},
            {"?commit=ABC", "commit"},
            {"?graph_sha256=abc", "graph_sha256"},
            {"?branch=#{String.duplicate("b", 257)}", "branch"},
            {"?branch=a%0Ab", "branch"},
            {"?branch=", "branch"},
            {"?event=%20%20", "event"},
            {"?event=#{String.duplicate("e", 65)}", "event"},
            {"?limit=0", "limit"},
            {"?cursor=nope", "cursor"}
          ] do
        body = ctx.sk_conn |> list(ctx.project.slug, query) |> json_response(422)
        assert body["errors"][field], field
      end
    end

    test "show round-trips the document and 404s for another project or uppercase id", ctx do
      run_id = "abcdefab-cdef-4abc-8def-abcdefabcdef"
      document = Map.put(full(), "run_id", run_id)
      ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)

      body = ctx.sk_conn |> show(ctx.project.slug, run_id) |> json_response(200)
      assert_schema(body, "WorkflowRunResponse", spec())
      assert body["data"]["document"] == document
      assert body["data"]["run_id"] == run_id
      assert body["data"]["test_reports"] == []

      other = project_fixture(ctx.account)
      assert ctx.sk_conn |> show(other.slug, run_id) |> json_response(404)
      assert ctx.sk_conn |> show(ctx.project.slug, String.upcase(run_id)) |> json_response(404)
    end

    test "show of a run that belongs to another account is 404", ctx do
      run_id = minimal()["run_id"]
      ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(201)

      other_project = project_fixture(ctx.other_account, %{slug: ctx.project.slug})

      assert ctx.other_conn |> show(other_project.slug, run_id) |> json_response(404)
    end

    test "a public key sees null command and error, and the stored row is unchanged", ctx do
      sentinel = "SENTINEL-command-7c21"

      document =
        full()
        |> put_in(["results", Access.at(0), "command"], sentinel)
        |> put_in(["results", Access.at(0), "error"], sentinel)

      ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)
      run_id = document["run_id"]

      redacted = ctx.pk_conn |> show(ctx.project.slug, run_id) |> json_response(200)
      refute redacted |> inspect() =~ sentinel

      stored = Repo.get_by!(Run, run_id: run_id)

      expected =
        update_in(stored.payload, ["results", Access.all()], fn result ->
          result |> Map.put("command", nil) |> Map.put("error", nil)
        end)

      assert redacted["data"]["document"] == expected

      revealed = ctx.sk_conn |> show(ctx.project.slug, run_id) |> json_response(200)
      assert hd(revealed["data"]["document"]["results"])["command"] == sentinel
      assert hd(revealed["data"]["document"]["results"])["error"] == sentinel

      assert hd(stored.payload["results"])["command"] == sentinel
      assert hd(stored.payload["results"])["error"] == sentinel
    end

    test "a public key sees null graph command and condition text", ctx do
      sentinel = "SENTINEL-graph-5d02"
      jobs = ["graph", "jobs"]

      document =
        goodflows("full")
        |> put_in(jobs ++ [Access.at(0), "command"], sentinel)
        |> put_in(jobs ++ [Access.at(0), "condition", "text"], sentinel)
        |> put_in(jobs ++ [Access.at(1), "steps", Access.at(0), "command"], sentinel)
        |> put_in(jobs ++ [Access.at(1), "steps", Access.at(0), "condition", "text"], sentinel)

      ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)

      redacted = ctx.pk_conn |> show(ctx.project.slug, document["run_id"]) |> json_response(200)
      assert_schema(redacted, "WorkflowRunResponse", spec())
      refute inspect(redacted) =~ sentinel

      [build, test, call] = redacted["data"]["document"]["graph"]["jobs"]
      assert build["command"] == nil
      assert build["condition"] == %{"kind" => "expression", "text" => nil}
      assert Enum.map(test["steps"], & &1["command"]) == [nil, nil]
      assert hd(test["steps"])["condition"] == %{"kind" => "shell", "text" => nil}
      assert call["call"] == document["graph"]["jobs"] |> Enum.at(2) |> Map.fetch!("call")
      assert build["depends_on"] == [] and test["depends_on"] == ["build"]
      assert redacted["data"]["document"]["ci"] == document["ci"]

      revealed = ctx.sk_conn |> show(ctx.project.slug, document["run_id"]) |> json_response(200)
      assert revealed["data"]["document"] == document
    end

    test "show lists test reports stored before the run, in job then report_id order", ctx do
      run_id = minimal()["run_id"]

      first =
        "complete"
        |> report()
        |> Map.put("workflow_run_id", run_id)
        |> Map.put("job", "zzz")
        |> with_report_id("aaa-report")

      second =
        "complete"
        |> report()
        |> Map.put("workflow_run_id", run_id)
        |> Map.put("job", "aaa")
        |> with_report_id("zzz-report")

      stored_report_fixture(ctx.account, ctx.project, first)
      stored_report_fixture(ctx.account, ctx.project, second)

      elsewhere = project_fixture(ctx.account)

      "complete"
      |> report()
      |> Map.put("workflow_run_id", run_id)
      |> Map.put("job", "mmm")
      |> with_report_id("mmm-report")
      |> then(&stored_report_fixture(ctx.account, elsewhere, &1))

      ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(201)

      body = ctx.sk_conn |> show(ctx.project.slug, run_id) |> json_response(200)
      [alpha, zed] = body["data"]["test_reports"]

      assert alpha["job"] == "aaa"
      assert alpha["report_id"] == "zzz-report"
      assert zed["job"] == "zzz"
      assert zed["report_id"] == "aaa-report"

      for report <- [alpha, zed] do
        assert Map.keys(report) |> Enum.sort() ==
                 ~w(id job job_status partition partition_count report_id status suite_id)

        refute inspect(report) =~ "adds numbers"
        refute Map.has_key?(report, "records")
      end

      other_show = ctx.sk_conn |> show(elsewhere.slug, run_id) |> json_response(404)
      assert other_show
    end
  end

  describe "links" do
    test "an upload with links is 201 and an sk_ show returns it as written", ctx do
      document =
        with_links(%{
          "threads" => [@thread, @threads <> "a%7Eb", @threads <> "a%2fb"],
          "tickets" => ["goo-291", "GOO-300"]
        })

      assert_schema(document, "WorkflowRunRequest", spec())
      ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)

      shown = ctx.sk_conn |> show(ctx.project.slug, document["run_id"]) |> json_response(200)
      assert_schema(shown, "WorkflowRunResponse", spec())
      assert shown["data"]["document"] == document
      assert shown["data"]["document"]["links"]["tickets"] == ["goo-291", "GOO-300"]

      assert shown["data"]["document"]["links"]["threads"] ==
               [@thread, @threads <> "a%7Eb", @threads <> "a%2fb"]

      tickets_only =
        with_links(%{"tickets" => ["GOO-291"]}, %{
          "run_id" => "22222222-2222-4222-8222-222222222222"
        })

      ctx.sk_conn
      |> upload(ctx.project.slug, Jason.encode!(tickets_only))
      |> json_response(201)
    end

    test "each invalid links value is 422 on its path, does not echo it, and stores nothing",
         ctx do
      oversized = @threads <> String.duplicate("a", 2049 - byte_size(@threads))
      many = for i <- 1..33, do: @threads <> "T-#{i}"

      threads = fn url -> %{"threads" => [url]} end
      tickets = fn ticket -> %{"tickets" => [ticket]} end

      cases = [
        {%{}, "links", nil},
        {%{"tickets" => ["GOO-291"], "prs" => [1]}, "links", "prs"},
        {%{"threads" => nil, "tickets" => ["GOO-291"]}, "links.threads", nil},
        {%{"tickets" => []}, "links.tickets", nil},
        {%{"threads" => many}, "links.threads", nil},
        {threads.(@threads <> "T-1?token=secret"), "links.threads[0]", "secret"},
        {threads.(@threads <> "T-1?"), "links.threads[0]", nil},
        {threads.(@threads <> "T-1#"), "links.threads[0]", nil},
        {threads.("http://ampcode.com/threads/T-1"), "links.threads[0]", nil},
        {threads.("HTTPS://ampcode.com/threads/T-1"), "links.threads[0]", nil},
        {threads.("https://user:pw@ampcode.com/threads/T-1"), "links.threads[0]", "user:pw"},
        {threads.(oversized), "links.threads[0]", "aaaa"},
        {%{"threads" => [@thread, @thread]}, "links.threads[1]", "ampcode"},
        {threads.(@threads <> "T-1[x]"), "links.threads[0]", nil},
        {threads.(@threads <> "T|1"), "links.threads[0]", nil},
        {threads.(@threads <> "T-1%zz"), "links.threads[0]", nil},
        {threads.(@threads <> "T-1%"), "links.threads[0]", nil},
        {threads.("https://AmpCode.com/threads/T-1"), "links.threads[0]", "AmpCode"},
        {threads.("https://ampcode.com:443/threads/T-1"), "links.threads[0]", nil},
        {threads.("https://ampcode.com:0443/threads/T-1"), "links.threads[0]", nil},
        {threads.("https://ampcode.com"), "links.threads[0]", nil},
        {threads.("https://ampcode.com/a/../threads/T-1"), "links.threads[0]", nil},
        {threads.("https://ampcode.com/a/%2E%2e/threads/T-1"), "links.threads[0]", nil},
        {threads.("https://ex%61mple.com/threads/T-1"), "links.threads[0]", "ex%61mple"},
        {threads.("https://0x7f.1/threads/T-1"), "links.threads[0]", "0x7f"},
        {threads.("https://[0:0:0:0:0:0:0:1]/threads/T-1"), "links.threads[0]", nil},
        {%{"tickets" => ["GOO-1", "GOO-2", "goo-1"]}, "links.tickets[2]", "GOO"},
        {tickets.("GOO 1"), "links.tickets[0]", "GOO 1"},
        {tickets.("GOO-1,GOO-2"), "links.tickets[0]", "GOO-1,GOO-2"},
        {tickets.(""), "links.tickets[0]", nil},
        {tickets.(String.duplicate("T", 65)), "links.tickets[0]", "TTTT"},
        {tickets.("GOÖ-1"), "links.tickets[0]", "GOÖ"}
      ]

      for {links, path, value} <- cases do
        body = ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(with_links(links)))
        response = json_response(body, 422)
        assert_schema(response, "ValidationErrorResponse", spec())
        errors = response["errors"]
        assert Map.has_key?(errors, path), "expected #{path}, got #{inspect(errors)}"
        if value, do: refute(body.resp_body =~ value, "#{path} echoed #{value}")
      end

      normalized =
        ctx.sk_conn
        |> upload(ctx.project.slug, Jason.encode!(with_links(threads.("https://ampcode.com"))))
        |> json_response(422)

      assert normalized == %{"errors" => %{"links.threads[0]" => ["must be normalized"]}}
      assert run_count() == 0
    end

    test "sk_ and pk_ keys list by ticket and thread_url, and summaries gain no links", ctx do
      pr_run = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      main_run = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      bare_run = "ffffffff-ffff-4fff-8fff-ffffffffffff"

      for document <- [
            with_links(%{"threads" => [@thread], "tickets" => ["GOO-291"]}, %{
              "run_id" => pr_run,
              "started_at" => "2026-11-05T12:00:00Z"
            }),
            with_links(%{"tickets" => ["goo-291"]}, %{
              "run_id" => main_run,
              "started_at" => "2026-11-06T12:00:00Z",
              "source" => %{"commit" => String.duplicate("a", 40), "branch" => "main"}
            }),
            Map.merge(minimal(), %{"run_id" => bare_run, "started_at" => "2026-11-07T12:00:00Z"})
          ] do
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)
      end

      respelled =
        URI.encode_www_form(
          "HTTPS://AmpCode.com:443/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"
        )

      for conn <- [ctx.sk_conn, ctx.pk_conn] do
        assert run_ids(conn, ctx.project.slug, "?ticket=GOO-291") == [main_run, pr_run]
        assert run_ids(conn, ctx.project.slug, "?ticket=goo-291&branch=main") == [main_run]
        assert run_ids(conn, ctx.project.slug, "?thread_url=#{respelled}") == [pr_run]
        assert run_ids(conn, ctx.project.slug, "?ticket=GOO-300") == []

        page = conn |> list(ctx.project.slug) |> json_response(200)
        assert length(page["data"]) == 3
        refute inspect(page) =~ "ampcode"
        refute inspect(page) =~ ~r/goo-291/i

        for summary <- page["data"] do
          assert Map.keys(summary) |> Enum.sort() ==
                   ~w(ci duration_ms environment failed_jobs graph_sha256 host id inserted_at
                      max_in_flight outcome parallelism run_id source started_at workflow)
        end
      end
    end

    test "invalid link filters are 422 on that parameter without echoing the value", ctx do
      for {query, field, value} <- [
            {"?ticket=GOO%20SECRET1", "ticket", "SECRET1"},
            {"?ticket=GOO-1%2CSECRET2", "ticket", "SECRET2"},
            {"?ticket=" <> String.duplicate("S", 65), "ticket", "SSSS"},
            {"?ticket=", "ticket", nil},
            {"?thread_url=" <> URI.encode_www_form(@thread <> "?token=secret"), "thread_url",
             "secret"},
            {"?thread_url=" <> URI.encode_www_form("http://secrethost.example/a"), "thread_url",
             "secrethost"},
            {"?thread_url=" <> URI.encode_www_form("https://ampcode.com/a/../SECRET3"),
             "thread_url", "SECRET3"},
            {"?thread_url=" <> URI.encode_www_form(@threads <> "SECRET4%zz"), "thread_url",
             "SECRET4"}
          ] do
        for conn <- [ctx.sk_conn, ctx.pk_conn] do
          response = conn |> list(ctx.project.slug, query)
          body = json_response(response, 422)
          assert body["errors"][field] == ["is invalid"], query
          if value, do: refute(response.resp_body =~ value, query)
        end
      end
    end
  end

  describe "project deletion" do
    test "a project whose only content is a workflow run is 409", ctx do
      %{"data" => %{"id" => id}} =
        ctx.sk_conn |> upload(ctx.project.slug, json("minimal")) |> json_response(201)

      body = ctx.sk_conn |> delete(~p"/api/v1/projects/#{ctx.project.slug}") |> json_response(409)
      assert body["errors"]["detail"] =~ "workflow runs"
      refute inspect(body) =~ id
      assert Repo.get(Run, id)
    end
  end
end
