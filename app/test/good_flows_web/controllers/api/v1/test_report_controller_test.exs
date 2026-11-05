defmodule GoodFlowsWeb.Api.V1.TestReportControllerTest do
  use GoodFlowsWeb.ConnCase, async: true
  use Mimic

  setup :verify_on_exit!

  import Ecto.Query
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.{Accounts, Repo}
  alias GoodFlows.Spry.{Run, RunStep}
  alias GoodFlows.TestReports.{Report, Store}
  alias GoodFlowsWeb.ApiSpec
  alias GoodFlowsWeb.Plugs.{BodyParsers, TestReportBody}

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp upload(conn, slug, body, content_type \\ "application/json") do
    conn
    |> put_req_header("content-type", content_type)
    |> post("/api/v1/projects/#{slug}/test-reports", body)
  end

  defp report_count, do: Repo.aggregate(Report, :count)

  # The test adapter keeps the unread request body: a conn whose body was
  # never read still returns all of it.
  defp body_unread?(conn, body), do: match?({:ok, ^body, _}, Plug.Conn.read_body(conn))

  defp spec, do: ApiSpec.spec()

  describe "storing" do
    test "201 stores a report; an exact retry is 200 with the same id", ctx do
      body = report_json("complete")

      created = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
      assert_schema(created, "TestReportAcknowledgement", spec())

      assert %{
               "id" => id,
               "report_id" => "report-1",
               "status" => "complete",
               "duplicate" => false
             } =
               created["data"]

      retry = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(200)
      assert_schema(retry, "TestReportAcknowledgement", spec())
      assert retry["data"] == %{created["data"] | "duplicate" => true}

      assert %Report{project_id: project_id, account_id: account_id, api_key_id: key_id} =
               Repo.get!(Report, id)

      assert project_id == ctx.project.id
      assert account_id == ctx.account.id
      assert key_id == ctx.sk_key.id
      assert report_count() == 1
    end

    test "every contract fixture is accepted with its status, and acknowledgements omit content",
         ctx do
      for {name, status} <- [
            {"complete", "complete"},
            {"failed", "complete"},
            {"incomplete", "incomplete"}
          ] do
        body = ctx.sk_conn |> upload(ctx.project.slug, report_json(name)) |> json_response(201)
        assert body["data"]["status"] == status
        assert Map.keys(body["data"]) |> Enum.sort() == ~w(duplicate id report_id status)
      end
    end

    test "charset=utf-8 is accepted", ctx do
      assert ctx.sk_conn
             |> upload(
               ctx.project.slug,
               report_json("complete"),
               "application/json; charset=UTF-8"
             )
             |> json_response(201)
    end

    test "a changed body under a stored identity is 409 without the stored id", ctx do
      %{"data" => %{"id" => id}} =
        ctx.sk_conn |> upload(ctx.project.slug, report_json("complete")) |> json_response(201)

      changed = report("complete") |> Map.put("job_status", "failed") |> Jason.encode!()
      body = ctx.sk_conn |> upload(ctx.project.slug, changed) |> json_response(409)

      assert_schema(body, "ConflictResponse", spec())
      refute inspect(body) =~ id
      assert report_count() == 1
    end

    test "the same identity in another account is stored separately", ctx do
      other_project = project_fixture(ctx.other_account, %{"slug" => ctx.project.slug})

      mine =
        ctx.sk_conn |> upload(ctx.project.slug, report_json("complete")) |> json_response(201)

      changed = report("complete") |> Map.put("job_status", "failed") |> Jason.encode!()
      theirs = ctx.other_conn |> upload(other_project.slug, changed) |> json_response(201)

      refute theirs["data"]["id"] == mine["data"]["id"]
      assert theirs["data"]["duplicate"] == false
    end

    test "query parameters are ignored", ctx do
      body =
        ctx.sk_conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/v1/projects/#{ctx.project.slug}/test-reports?project=x&account_id=y",
          report_json("complete")
        )
        |> json_response(201)

      assert Repo.get!(Report, body["data"]["id"]).project_id == ctx.project.id
    end

    test "storage never starts a Spry job or writes run tables", ctx do
      reject(&PgFlow.enqueue/2)
      reject(&GoodFlows.Spry.request_run/5)

      ctx.sk_conn |> upload(ctx.project.slug, report_json("complete")) |> json_response(201)

      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(RunStep, :count) == 0
      assert queued_job_messages() == 0
    end
  end

  describe "authentication and project" do
    test "missing, expired and revoked keys are 401 without reading the body", ctx do
      body = report_json("complete")
      ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)

      account_user = Accounts.get_account_user(user_of(ctx.sk_key), ctx.account)

      {expired, expired_token} =
        GoodFlows.AccountsFixtures.api_key_fixture(account_user, %{type: :private})

      Repo.update_all(where(Accounts.ApiKey, id: ^expired.id),
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
        # An exact retry of the stored report is refused too.
        conn = upload(conn, ctx.project.slug, body)
        assert json_response(conn, 401)
        assert body_unread?(conn, body)
      end

      assert report_count() == 1
    end

    test "a public key is 403 before the slug is validated", ctx do
      body = report_json("complete")

      for slug <- [ctx.project.slug, "missing", "GoodCases"] do
        conn = upload(ctx.pk_conn, slug, body)
        assert json_response(conn, 403)
        assert body_unread?(conn, body)
      end

      assert report_count() == 0
    end

    test "an unknown or other-account slug is 404 without reading the body", ctx do
      other_project = project_fixture(ctx.other_account)
      body = report_json("complete")

      for slug <- ["missing", other_project.slug] do
        conn = upload(ctx.sk_conn, slug, body)
        assert_schema(json_response(conn, 404), "ErrorResponse", spec())
        assert body_unread?(conn, body)
      end

      assert report_count() == 0
    end

    test "an invalid slug is 422 on project without reading the body", ctx do
      body = report_json("complete")

      for slug <- ["GoodCases", "-app"] do
        conn = upload(ctx.sk_conn, slug, body)
        response = json_response(conn, 422)
        assert_schema(response, "ValidationErrorResponse", spec())
        assert response["errors"]["project"]
        assert body_unread?(conn, body)
      end

      assert report_count() == 0
    end

    test "unauthenticated oversized uploads are 401 without reading", %{project: project} do
      body = String.duplicate(" ", TestReportBody.max_body_bytes() + 10)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> upload(project.slug, body)

      assert json_response(conn, 401)
      assert body_unread?(conn, body)
    end

    test "a missing project with an oversized body is 404 without reading", ctx do
      body = String.duplicate(" ", TestReportBody.max_body_bytes() + 10)
      conn = upload(ctx.sk_conn, "missing", body)

      assert json_response(conn, 404)
      assert body_unread?(conn, body)
    end
  end

  describe "body handling" do
    test "a declared Content-Length over the limit is 413 before reading", ctx do
      body = report_json("complete")
      limit = TestReportBody.max_body_bytes()

      conn =
        ctx.sk_conn
        |> put_req_header("content-length", Integer.to_string(limit + 1))
        |> upload(ctx.project.slug, body)

      assert_schema(json_response(conn, 413), "ErrorResponse", spec())
      assert body_unread?(conn, body)
      assert report_count() == 0
    end

    test "an understated or absent length with an oversized body is 413", ctx do
      body = String.duplicate(" ", TestReportBody.max_body_bytes() + 1)

      assert ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(413)

      assert ctx.sk_conn
             |> put_req_header("content-length", "10")
             |> upload(ctx.project.slug, body)
             |> json_response(413)

      assert report_count() == 0
    end

    test "a body exactly at the limit is read", ctx do
      json = report_json("complete")
      limit = TestReportBody.max_body_bytes()
      padded = json <> String.duplicate(" ", limit - byte_size(json))
      assert byte_size(padded) == limit

      assert ctx.sk_conn |> upload(ctx.project.slug, padded) |> json_response(201)
      assert ctx.sk_conn |> upload(ctx.project.slug, padded <> " ") |> json_response(413)
    end

    test "malformed JSON is 400 with a fixed message", ctx do
      sentinel = "SENTINEL-malformed-55e1"

      body =
        ctx.sk_conn
        |> upload(ctx.project.slug, ~s({"job": "#{sentinel}", ))
        |> json_response(400)

      assert_schema(body, "ErrorResponse", spec())
      refute inspect(body) =~ sentinel
    end

    test "nesting deeper than the contract allows is 422 on body before decoding", ctx do
      deep = String.duplicate("[", 17) <> String.duplicate("]", 17)
      body = ctx.sk_conn |> upload(ctx.project.slug, deep) |> json_response(422)

      assert_schema(body, "ValidationErrorResponse", spec())
      assert body["errors"] == %{"body" => ["is nested too deeply"]}

      # Malformed but deep bodies are rejected by the scan, not the decoder.
      assert ctx.sk_conn
             |> upload(ctx.project.slug, String.duplicate("[", 10_000))
             |> json_response(422)

      assert report_count() == 0
    end

    test "non-JSON content types and any non-identity encoding are 415", ctx do
      json = report_json("complete")

      for type <- [
            "text/plain",
            "application/x-www-form-urlencoded",
            "application/json; charset=latin1",
            "application/vnd.api+json"
          ] do
        conn = upload(ctx.sk_conn, ctx.project.slug, json, type)
        assert_schema(json_response(conn, 415), "ErrorResponse", spec())
        assert body_unread?(conn, json)
      end

      for encoding <- ["gzip", "deflate", "br", "identity, gzip"] do
        conn =
          ctx.sk_conn
          |> put_req_header("content-encoding", encoding)
          |> upload(ctx.project.slug, json)

        assert json_response(conn, 415)
        assert body_unread?(conn, json)
      end

      assert ctx.sk_conn
             |> put_req_header("content-encoding", "identity")
             |> upload(ctx.project.slug, json)
             |> json_response(201)
    end

    test "parser errors are JSON whatever the Accept header allows", ctx do
      conn =
        build_conn()
        |> put_req_header("authorization", conn_token(ctx.sk_conn))
        |> put_req_header("accept", "*/*")
        |> upload(ctx.project.slug, "{")

      assert json_response(conn, 400)
    end

    test "a retired-format report is 422 with only the format error", ctx do
      retired =
        report("complete")
        |> Map.put("format", "exunit-timings")
        |> put_at(["report", "records", 0, "format"], "exunit-timings")
        |> put_at(["report", "records", 0, "run_id"], "suite-20261101-a")

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(retired)) |> json_response(422)

      assert_schema(body, "ValidationErrorResponse", spec())
      assert body == %{"errors" => %{"format" => ["is invalid"]}}
      assert report_count() == 0
    end

    test "validation errors are 422 keyed by JSON path", ctx do
      document = put_at(report("complete"), ["report", "records", 3, "duration_us"], -1)

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(422)

      assert_schema(body, "ValidationErrorResponse", spec())
      assert body["errors"]["report.records[3].duration_us"] == ["must be a nonnegative integer"]
      assert report_count() == 0
    end

    test "suite filters with any boolean identifier tag are stored in order", ctx do
      include = [%{"tag" => "slow", "value" => true}]

      exclude = [
        %{"tag" => "Chrome", "value" => true},
        %{"tag" => "chrome", "value" => true},
        %{"tag" => "slow", "value" => true},
        %{"tag" => "slow", "value" => false}
      ]

      document =
        put_at(report("complete"), ["report", "records", 0, "filters"], %{
          "include" => include,
          "exclude" => exclude
        })

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(201)

      %Report{payload: payload} = Repo.get!(Report, body["data"]["id"])

      assert hd(payload["report"]["records"])["filters"] == %{
               "include" => include,
               "exclude" => exclude
             }
    end

    test "a suite filter tag outside the identifier grammar is 422 without echo", ctx do
      count = report_count()

      document =
        put_at(report("complete"), ["report", "records", 0, "filters", "include"], [
          %{"tag" => "slow test", "value" => true}
        ])

      conn = upload(ctx.sk_conn, ctx.project.slug, Jason.encode!(document))
      body = json_response(conn, 422)

      assert body["errors"]["report.records[0].filters.include[0].tag"] == ["has invalid format"]
      refute conn.resp_body =~ "slow test"
      assert report_count() == count
    end

    test "a suite filter list over 256 entries is 422 on the list", ctx do
      count = report_count()

      document =
        put_at(
          report("complete"),
          ["report", "records", 0, "filters", "include"],
          List.duplicate(%{"tag" => "slow", "value" => true}, 257)
        )

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(422)

      assert body["errors"] == %{
               "report.records[0].filters.include" => ["must not have more than 256 entries"]
             }

      assert report_count() == count
    end

    test "a non-boolean suite filter value is 422", ctx do
      count = report_count()

      document =
        put_at(report("complete"), ["report", "records", 0, "filters", "exclude"], [
          %{"tag" => "qpdf", "value" => "on"}
        ])

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(422)

      assert body["errors"] == %{
               "report.records[0].filters.exclude[0].value" => ["must be a boolean"]
             }

      assert report_count() == count
    end

    test "an empty source branch is 422 on source.branch", ctx do
      document = put_at(report("complete"), ["source", "branch"], "")

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(422)

      assert Map.keys(body["errors"]) == ["source.branch"]
      assert report_count() == 0
    end

    test "a body project is 422 as an unknown field on the body", ctx do
      document = Map.put(report("complete"), "project", ctx.project.slug)

      body =
        ctx.sk_conn |> upload(ctx.project.slug, Jason.encode!(document)) |> json_response(422)

      # Reported on the body without echoing the submitted key name.
      assert body["errors"] == %{"body" => ["has an unknown field"]}
      assert report_count() == 0
    end

    test "storage failure is 503 with Retry-After and no acknowledgement", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise DBConnection.ConnectionError, "connection refused"
      end)

      conn = upload(ctx.sk_conn, ctx.project.slug, report_json("complete"))

      assert_schema(json_response(conn, 503), "ErrorResponse", spec())
      assert get_resp_header(conn, "retry-after") == ["1"]
      refute json_response(conn, 503)["data"]
      assert report_count() == 0
    end

    test "a key deleted between auth and insert is 503; the retry fails auth", ctx do
      expect(Store, :insert_all, fn schema, rows, opts ->
        Repo.delete_all(where(Accounts.ApiKey, id: ^ctx.sk_key.id))
        call_original(Store, :insert_all, [schema, rows, opts])
      end)

      body = report_json("complete")
      conn = upload(ctx.sk_conn, ctx.project.slug, body)

      assert_schema(json_response(conn, 503), "ErrorResponse", spec())
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert report_count() == 0

      assert ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(401)
      assert report_count() == 0
    end

    test "after a lost commit confirmation the exact retry is 200 with the committed id", ctx do
      expect(Store, :insert_all, fn schema, rows, opts ->
        _committed = call_original(Store, :insert_all, [schema, rows, opts])
        raise DBConnection.ConnectionError, "connection closed"
      end)

      body = report_json("complete")
      assert ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(503)

      [committed] = Repo.all(from r in Report, select: r.id)

      retry = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(200)
      assert retry["data"]["id"] == committed
      assert retry["data"]["duplicate"]
      assert report_count() == 1
    end
  end

  describe "unrelated routes" do
    test "other routes keep the endpoint parser, including nested recipe routes", ctx do
      body = recipe_attrs(%{"name" => "parsed-recipe"})

      assert ctx.sk_conn
             |> post(~p"/api/v1/projects/#{ctx.project.slug}/recipes", body)
             |> json_response(201)

      assert ctx.sk_conn
             |> post(~p"/api/v1/projects", %{"slug" => "parsed"})
             |> json_response(201)
    end

    test "recipe uploads never get the test report plug's 413 or 415", ctx do
      path = ~p"/api/v1/projects/#{ctx.project.slug}/recipes"

      # Above the test report limit, but within the endpoint parser's.
      big =
        recipe_attrs(%{
          "name" => "big-recipe",
          "padding" => String.duplicate("x", TestReportBody.max_body_bytes() + 1)
        })

      conn =
        ctx.sk_conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(big))

      refute conn.status in [413, 415]

      # Content-Encoding is ignored by the endpoint parser.
      conn =
        ctx.sk_conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-encoding", "gzip")
        |> post(path, Jason.encode!(recipe_attrs(%{"name" => "gzip-recipe"})))

      assert json_response(conn, 201)

      # text/plain passes the endpoint parser untouched and unhalted (the
      # router's RequireParsedBody then answers 415; see its own test).
      opts =
        BodyParsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

      conn =
        :post
        |> Phoenix.ConnTest.build_conn(path, "name=plain")
        |> put_req_header("content-type", "text/plain")
        |> BodyParsers.call(opts)

      refute conn.halted
      assert conn.status == nil
    end

    test "the unparsed path shape is exactly the routed test report upload" do
      info =
        Phoenix.Router.route_info(
          GoodFlowsWeb.Router,
          "POST",
          "/api/v1/projects/p/test-reports",
          ""
        )

      assert %{plug: GoodFlowsWeb.Api.V1.TestReportController, plug_opts: :create} = info
      assert BodyParsers.test_report_upload?(~w(api v1 projects p test-reports))

      # Every routed path the body parser skips belongs to the upload action.
      for route <- GoodFlowsWeb.Router.__routes__() do
        path_info =
          route.path
          |> String.split("/", trim: true)
          |> Enum.map(&String.replace(&1, ~r/^:.*/, "x"))

        if BodyParsers.test_report_upload?(path_info) do
          assert {route.verb, route.plug, route.plug_opts} ==
                   {:post, GoodFlowsWeb.Api.V1.TestReportController, :create}
        end
      end
    end

    test "a test-reports path elsewhere is parsed normally" do
      assert BodyParsers.test_report_upload?(~w(api v1 projects goodcases test-reports))

      refute BodyParsers.test_report_upload?(~w(api v1 projects goodcases test-reports extra))

      refute BodyParsers.test_report_upload?(~w(api v1 test-reports))

      refute BodyParsers.test_report_upload?(~w(api v2 projects x test-reports))
    end
  end

  describe "project deletion" do
    test "a project with a stored report and no recipes is 409 and both remain", ctx do
      %{"data" => %{"id" => id}} =
        ctx.sk_conn |> upload(ctx.project.slug, report_json("complete")) |> json_response(201)

      body = ctx.sk_conn |> delete(~p"/api/v1/projects/#{ctx.project.slug}") |> json_response(409)
      assert_schema(body, "ConflictResponse", spec())
      assert body["errors"]["detail"] =~ "test reports"
      refute inspect(body) =~ id

      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{ctx.project.slug}") |> json_response(200)
      assert Repo.get(Report, id)
    end

    test "a project with both recipes and reports is 409 and keeps both", ctx do
      recipe = recipe_fixture(ctx.project)

      %{"data" => %{"id" => id}} =
        ctx.sk_conn |> upload(ctx.project.slug, report_json("complete")) |> json_response(201)

      assert ctx.sk_conn |> delete(~p"/api/v1/projects/#{ctx.project.slug}") |> json_response(409)

      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{ctx.project.slug}") |> json_response(200)
      assert Repo.get(Report, id)
      assert Repo.get(GoodFlows.Spry.Recipe, recipe.id)
    end

    test "recipe-only and report-only projects are protected; one with neither is deletable",
         ctx do
      recipes_only = project_fixture(ctx.account)
      recipe_fixture(recipes_only)

      reports_only = project_fixture(ctx.account)
      ctx.sk_conn |> upload(reports_only.slug, report_json("complete")) |> json_response(201)

      neither = project_fixture(ctx.account)

      assert ctx.sk_conn
             |> delete(~p"/api/v1/projects/#{recipes_only.slug}")
             |> json_response(409)

      assert ctx.sk_conn
             |> delete(~p"/api/v1/projects/#{reports_only.slug}")
             |> json_response(409)

      assert ctx.sk_conn |> delete(~p"/api/v1/projects/#{neither.slug}") |> response(204)
      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{neither.slug}") |> json_response(404)
    end
  end

  defp user_of(api_key) do
    api_key |> Repo.preload(account_user: :user) |> then(& &1.account_user.user)
  end

  defp conn_token(conn), do: conn |> get_req_header("authorization") |> hd()
end
