defmodule GoodFlowsWeb.Api.V1.OpenApiTest do
  use GoodFlowsWeb.ConnCase, async: true

  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects.Project
  alias GoodFlows.Review.Items

  test "serves the OpenAPI spec", %{conn: conn} do
    spec = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    assert spec["info"]["title"] == "GoodFlows API"
    assert spec["paths"]["/api/v1/me"]["get"]["operationId"]
    assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
  end

  test "retired pool endpoints and socket transport return 404", %{conn: conn} do
    id = Ecto.UUID.generate()

    for {method, path} <- [
          {:get, "/api/v1/projects/example/pools"},
          {:get, "/api/v1/pool-sessions/#{id}"},
          {:put, "/api/v1/pool-sessions/#{id}/workspace"},
          {:get, "/api/v1/pool-execs/#{id}/reports/result.ndjson"},
          {:get, "/api/v1/socket/websocket?vsn=2.0.0"}
        ] do
      assert dispatch(conn, @endpoint, method, path).status == 404, "#{method} #{path}"
    end
  end

  test "OpenAPI contains no retired pool paths or schemas", %{conn: conn} do
    spec = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    for name <- Map.keys(spec["paths"]) ++ Map.keys(spec["components"]["schemas"]) do
      refute String.contains?(String.downcase(name), "pool"), name
    end
  end

  test "describes Spry in the API description", %{conn: conn} do
    description =
      conn |> get(~p"/api/v1/openapi") |> json_response(200) |> get_in(["info", "description"])

    assert description =~ "## Spry"
    assert description =~ "Host steps are not supported"
    assert description =~ "visible only to private keys"
    assert description =~ "does not guarantee"
    assert description =~ "1. **Create a project** with `POST /api/v1/projects`"
    assert description =~ "/api/v1/projects/{project}/recipes"
    refute description =~ "POST /api/v1/recipes"
    refute description =~ "unique per account"
  end

  @project_operations [
    {"/api/v1/projects/{project}", "get"},
    {"/api/v1/projects/{project}", "delete"},
    {"/api/v1/projects/{project}", "patch"},
    {"/api/v1/projects/{project}/cache-keys", "get"},
    {"/api/v1/projects/{project}/cache-keys", "post"},
    {"/api/v1/projects/{project}/cache-keys/{id}", "delete"},
    {"/api/v1/projects/{project}/caches", "get"},
    {"/api/v1/projects/{project}/caches/entries", "get"},
    {"/api/v1/projects/{project}/caches/entries", "delete"},
    {"/api/v1/projects/{project}/caches/entries/{key}", "get"},
    {"/api/v1/projects/{project}/caches/entries/{key}", "post"},
    {"/api/v1/projects/{project}/caches/entries/{key}", "delete"},
    {"/api/v1/projects/{project}/caches/uploads/{upload_id}/commit", "post"},
    {"/api/v1/projects/{project}/recipes", "get"},
    {"/api/v1/projects/{project}/recipes", "post"},
    {"/api/v1/projects/{project}/recipes/{id}", "get"},
    {"/api/v1/projects/{project}/recipes/{id}", "put"},
    {"/api/v1/projects/{project}/recipes/{id}", "delete"},
    {"/api/v1/projects/{project}/recipes/{id}/runs", "get"},
    {"/api/v1/projects/{project}/recipes/{id}/runs", "post"},
    {"/api/v1/projects/{project}/test-reports", "post"},
    {"/api/v1/projects/{project}/workflow-runs", "get"},
    {"/api/v1/projects/{project}/workflow-runs", "post"},
    {"/api/v1/projects/{project}/workflow-runs/{run_id}", "get"},
    {"/api/v1/projects/{project}/review-policy", "get"},
    {"/api/v1/projects/{project}/review-policy", "put"},
    {"/api/v1/projects/{project}/review-policy/versions", "get"},
    {"/api/v1/projects/{project}/review-policy/versions/{version}", "get"},
    {"/api/v1/projects/{project}/change-requests", "get"},
    {"/api/v1/projects/{project}/change-requests", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/ready", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/draft", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/close", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/reopen", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/merged", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/git-facts", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/git-facts/{head}", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/claims", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/claims/{head}", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/verdict", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/scenario-sets", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/scenario-sets", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/scenario-sets/{source}/versions/{version}",
     "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/scenario-sets/{source}/compare", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/scenario-sets/{source}/approvals",
     "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/scenario-sets/{source}/rejections",
     "post"},
    {"/api/v1/projects/{project}/verify-runs", "get"},
    {"/api/v1/projects/{project}/verify-runs", "post"},
    {"/api/v1/projects/{project}/verify-runs/{run_id}", "get"},
    {"/api/v1/projects/{project}/verify-runs/{run_id}/commit", "post"},
    {"/api/v1/projects/{project}/feature-index", "get"},
    {"/api/v1/projects/{project}/feature-index", "post"},
    {"/api/v1/projects/{project}/feature-index/versions", "get"},
    {"/api/v1/projects/{project}/feature-index/versions/{version}", "get"},
    {"/api/v1/projects/{project}/events", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/review", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/review/items/{item_id}/answers",
     "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/tasks", "get"},
    {"/api/v1/projects/{project}/change-requests/{number}/tasks/{task_id}/done", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/parent", "put"},
    {"/api/v1/projects/{project}/change-requests/{number}/parent", "delete"},
    {"/api/v1/projects/{project}/change-requests/{number}/retarget", "post"},
    {"/api/v1/projects/{project}/change-requests/{number}/merge-lease", "post"},
    {"/api/v1/projects/{project}/merge-leases/{lease_id}/heartbeat", "post"},
    {"/api/v1/projects/{project}/merge-leases/{lease_id}", "delete"},
    {"/api/v1/projects/{project}/defects", "get"},
    {"/api/v1/projects/{project}/defects", "post"},
    {"/api/v1/projects/{project}/calibration", "get"}
  ]

  test "documents the project slug rule on every project path parameter", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")

    documented =
      for {path, ops} <- paths,
          String.contains?(path, "{project}"),
          {verb, _op} <- ops,
          do: {path, verb}

    assert Enum.sort(documented) == Enum.sort(@project_operations)

    for {path, verb} <- @project_operations do
      params = get_in(paths, [path, verb, "parameters"]) || []

      assert [param] = Enum.filter(params, &match?(%{"name" => "project", "in" => "path"}, &1)),
             "#{verb} #{path} has no project path parameter"

      assert param["required"], "#{verb} #{path}: project parameter is not required"
      assert param["description"] =~ Project.slug_rule()
    end
  end

  describe "test reports" do
    import GoodFlows.TestReportFixtures
    import OpenApiSpex.TestAssertions

    alias GoodFlows.TestReports.Validator
    alias GoodFlowsWeb.ApiSpec
    alias GoodFlowsWeb.Schemas.TestReportParts

    setup %{conn: conn} do
      %{doc: conn |> get(~p"/api/v1/openapi") |> json_response(200)}
    end

    test "documents the upload operation and its responses", %{doc: doc} do
      op = doc["paths"]["/api/v1/projects/{project}/test-reports"]["post"]

      assert Enum.sort(Map.keys(op["responses"])) ==
               ~w(200 201 400 401 403 404 406 408 409 413 415 422 503)

      assert op["requestBody"]["content"]["application/json"]["schema"]["$ref"] =~
               "TestReportRequest"

      for code <- ["200", "201"] do
        assert op["responses"][code]["content"]["application/json"]["schema"]["$ref"] =~
                 "TestReportAcknowledgement"
      end

      for name <- ~w(TestReportRequest TestReportEvent TestReportAcknowledgement) do
        assert doc["components"]["schemas"][name], "missing schema #{name}"
      end
    end

    test "the request schema has no project or account_id property", %{doc: doc} do
      request = doc["components"]["schemas"]["TestReportRequest"]

      refute Map.has_key?(request["properties"], "project")
      refute Map.has_key?(request["properties"], "account_id")
      assert request["additionalProperties"] == false

      assert Enum.sort(request["required"]) ==
               ~w(environment format job job_status report source workflow workflow_run_id)
    end

    test "every contract fixture matches the request schema" do
      for name <- names() do
        assert_schema(report(name), "TestReportRequest", ApiSpec.spec())
      end
    end

    test "the schema rejects a body project and unknown events" do
      spec = ApiSpec.spec()
      schema = spec.components.schemas["TestReportRequest"]

      assert {:error, _} =
               OpenApiSpex.cast_value(Map.put(report("complete"), "project", "x"), schema, spec)

      bad_event = put_at(report("complete"), ["report", "records", 1, "event"], "paused")
      assert {:error, _} = OpenApiSpex.cast_value(bad_event, schema, spec)
    end

    test "the API description documents the endpoint and its rules", %{doc: doc} do
      description = doc["info"]["description"]

      assert description =~ "## Test reports"
      assert description =~ "POST /api/v1/projects/{project}/test-reports"
      assert description =~ "there is no read"
      assert description =~ "Per-report completeness"
      assert description =~ "exact retry"
      assert description =~ "33,554,432 bytes"
      refute description =~ "test-timing-reports"
      assert description =~ "uses the `suite_id` grammar"
      assert Validator.max_filters() == 256
      assert description =~ "each list has at most #{Validator.max_filters()} entries"
      assert description =~ "`test-timings/1`"
      assert description =~ "exactly what goodflows collection accepts"
      assert description =~ "`meta`"
      assert description =~ "`suite_id` (= `report.suite_id`)"
      refute description =~ "exunit-timings"
      refute description =~ "module_started"

      # Workflow runs document `run_id`. The retired test-report field must
      # stay out of the test-report section only.
      [_, test_reports | _] = String.split(description, "## Test reports")
      test_reports = test_reports |> String.split("## Workflow runs") |> hd()
      refute test_reports =~ "`run_id`"
    end

    test "suite filter tags are bounded identifiers in capped lists", %{doc: doc} do
      suite_started =
        Enum.find(
          doc["components"]["schemas"]["TestReportEvent"]["oneOf"],
          &(&1["title"] == "TestReport_SuiteStarted")
        )

      filters = suite_started["properties"]["filters"]["properties"]

      for list <- ["include", "exclude"] do
        assert filters[list]["maxItems"] == 256
        tag = filters[list]["items"]["properties"]["tag"]

        assert tag == %{
                 "type" => "string",
                 "minLength" => 1,
                 "maxLength" => 128,
                 "pattern" => "^[A-Za-z0-9][A-Za-z0-9._-]*$"
               }

        refute Map.has_key?(tag, "enum")
      end
    end

    test "meta is optional on every event and documented as flat and bounded", %{doc: doc} do
      for event <- doc["components"]["schemas"]["TestReportEvent"]["oneOf"] do
        refute "meta" in event["required"], event["title"]
        assert "suite_id" in event["required"]
        refute Map.has_key?(event["properties"], "run_id")

        meta = event["properties"]["meta"]
        assert meta["type"] == "object"
        assert meta["maxProperties"] == 32
        assert meta["description"] =~ "256 bytes"
        # OAS 3.0 ignores `nullable` without `type`, so every branch has it.
        branches = meta["additionalProperties"]["anyOf"]
        assert Enum.map(branches, & &1["type"]) == ~w(boolean integer string)
        assert Enum.all?(branches, &(&1["nullable"] == true))
        refute Map.has_key?(meta["additionalProperties"], "nullable")
      end
    end

    test "started_at documents the contract grammar", %{doc: doc} do
      suite_started =
        Enum.find(
          doc["components"]["schemas"]["TestReportEvent"]["oneOf"],
          &(&1["title"] == "TestReport_SuiteStarted")
        )

      started_at = suite_started["properties"]["started_at"]
      assert started_at["maxLength"] == 64

      for text <- ["never a space", "`-00:00`", "at most 60", "at least one", "64 bytes"],
          do: assert(started_at["description"] =~ text)

      assert suite_started["properties"]["filters"]["nullable"] == true
      refute Map.has_key?(started_at, "format")
      assert started_at["pattern"] == TestReportParts.timestamp_pattern()
      assert started_at["description"] =~ "checked by the server only"
    end

    @accepted_timestamps [
      "2026-11-01T00:00:00Z",
      "2026-11-01t00:00:00z",
      "2026-11-01T00:00:00.123456Z",
      "2026-11-01T00:00:00+00:00",
      "2026-11-01T00:00:00-00:00",
      "2026-12-31T23:59:60Z",
      "2024-02-29T12:00:00.1Z"
    ]

    @rejected_timestamps [
      "2026-11-01 00:00:00Z",
      "2026-11-01T00:00:00+01:00",
      "2026-11-01T00:00:00.Z",
      "2026-11-01T00:00:00",
      "2026-11-01",
      "2026-13-01T00:00:00Z",
      "2026-11-32T00:00:00Z",
      "2026-11-01T24:00:00Z",
      "2026-11-01T00:60:00Z",
      "2026-11-01T00:00:61Z",
      "2026-11-01T00:00:00.123456789012345678901234567890123456789012345Z"
    ]

    test "the started_at pattern matches the validator's grammar" do
      spec = ApiSpec.spec()
      schema = spec.components.schemas["TestReportRequest"]
      path = ["report", "records", 0, "started_at"]

      for value <- @accepted_timestamps do
        document = put_at(report("complete"), path, value)
        assert {:ok, _} = OpenApiSpex.cast_value(document, schema, spec), value
        assert {:ok, _, _} = Validator.validate(document), value
      end

      for value <- @rejected_timestamps do
        document = put_at(report("complete"), path, value)
        assert {:error, _} = OpenApiSpex.cast_value(document, schema, spec), value
        assert {:error, _} = Validator.validate(document), value
      end

      # Calendar validity is the server's alone: the pattern cannot see it.
      impossible = put_at(report("complete"), path, "2026-02-30T00:00:00Z")
      assert {:ok, _} = OpenApiSpex.cast_value(impossible, schema, spec)
      assert {:error, _} = Validator.validate(impossible)
    end

    test "meta values may be null in the request schema" do
      spec = ApiSpec.spec()
      schema = spec.components.schemas["TestReportRequest"]
      path = ["report", "records", 0, "meta"]

      for meta <- [%{"a" => nil}, %{"a" => true, "b" => 1, "c" => "x"}] do
        assert {:ok, _} =
                 OpenApiSpex.cast_value(put_at(report("complete"), path, meta), schema, spec)
      end

      assert {:error, _} =
               OpenApiSpex.cast_value(
                 put_at(report("complete"), path, %{"a" => [1]}),
                 schema,
                 spec
               )
    end

    test "a report with any identifier filter tag matches the request schema" do
      document =
        put_at(report("complete"), ["report", "records", 0, "filters", "include"], [
          %{"tag" => "slow", "value" => true}
        ])

      assert_schema(document, "TestReportRequest", ApiSpec.spec())
    end

    test "the request schema rejects a filter list over the cap" do
      spec = ApiSpec.spec()
      schema = spec.components.schemas["TestReportRequest"]
      path = ["report", "records", 0, "filters", "include"]
      entry = %{"tag" => "slow", "value" => true}

      at_cap = put_at(report("complete"), path, List.duplicate(entry, 256))
      assert {:ok, _} = OpenApiSpex.cast_value(at_cap, schema, spec)

      over_cap = put_at(report("complete"), path, List.duplicate(entry, 257))
      assert {:error, _} = OpenApiSpex.cast_value(over_cap, schema, spec)
    end
  end

  describe "workflow runs" do
    import GoodFlows.WorkflowRunFixtures
    import OpenApiSpex.TestAssertions

    alias GoodFlows.JsonDocument
    alias GoodFlows.TestReports.Validator, as: TestReportValidator
    alias GoodFlowsWeb.ApiSpec
    alias GoodFlowsWeb.Schemas.WorkflowRunParts

    setup %{conn: conn} do
      %{doc: conn |> get(~p"/api/v1/openapi") |> json_response(200)}
    end

    test "documents upload, list and show responses", %{doc: doc} do
      upload = doc["paths"]["/api/v1/projects/{project}/workflow-runs"]["post"]
      list = doc["paths"]["/api/v1/projects/{project}/workflow-runs"]["get"]
      show = doc["paths"]["/api/v1/projects/{project}/workflow-runs/{run_id}"]["get"]

      assert Enum.sort(Map.keys(upload["responses"])) ==
               ~w(200 201 400 401 403 404 406 408 409 413 415 422 503)

      assert Enum.sort(Map.keys(list["responses"])) == ~w(200 401 404 406 422)
      assert Enum.sort(Map.keys(show["responses"])) == ~w(200 401 404 406 422)

      assert upload["requestBody"]["content"]["application/json"]["schema"]["$ref"] =~
               "WorkflowRunRequest"

      for name <-
            ~w(WorkflowRunRequest WorkflowRunAcknowledgement WorkflowRunSummary WorkflowRunListResponse WorkflowRunResponse) do
        assert doc["components"]["schemas"][name], "missing schema #{name}"
      end

      query = Map.new(list["parameters"], &{&1["name"], &1})
      assert query["limit"]["schema"]["minimum"] == 1
      assert query["limit"]["schema"]["maximum"] == 200
      assert query["outcome"]["schema"]["enum"] == ["passed", "failed", "cancelled"]
      assert query["graph_sha256"]["schema"]["pattern"] =~ "64"
      assert query["run_id"] == nil
      assert show["parameters"] |> Enum.find(&(&1["name"] == "run_id")) |> Map.fetch!("required")

      job_status =
        doc["components"]["schemas"]["WorkflowRunResponse"]["properties"]["data"]["properties"][
          "test_reports"
        ]["items"]["properties"]["job_status"]

      assert job_status["enum"] == TestReportValidator.job_statuses()
    end

    test "the request schema lists only required keys and nulls only nullable keys", %{doc: doc} do
      request = doc["components"]["schemas"]["WorkflowRunRequest"]

      assert Enum.sort(request["required"]) ==
               ~w(duration_ms graph_sha256 host max_in_flight outcome parallelism results run_id schema_version started_at workflow)

      refute "environment" in request["required"]
      refute request["properties"]["environment"]["nullable"]
      refute "source" in request["required"]
      refute Map.has_key?(request["properties"], "project")

      for key <- ~w(graph ci) do
        refute key in request["required"]
        refute request["properties"][key]["nullable"]
      end

      refute "branch" in request["properties"]["source"]["required"]
      assert request["properties"]["source"]["properties"]["branch"]["maxLength"] == 256
      assert request["properties"]["ci"]["required"] == ["provider"]

      job = request["properties"]["graph"]["properties"]["jobs"]["items"]
      assert request["properties"]["graph"]["properties"]["jobs"]["maxItems"] == 1024

      assert Enum.sort(job["required"]) ==
               ~w(command condition depends_on name partitions shell steps timeout_secs)

      for key <- ~w(command partitions timeout_secs condition) do
        assert job["properties"][key]["nullable"]
      end

      refute job["properties"]["call"]["nullable"]
      assert Enum.sort(job["properties"]["call"]["required"]) == ~w(graph_sha256 workflow)
      assert job["properties"]["call"]["additionalProperties"] == false

      result = request["properties"]["results"]["items"]

      for key <- ~w(command error exit_code) do
        assert key in result["required"]
        assert result["properties"][key]["nullable"]
      end

      refute "workflow" in result["required"]
      refute result["properties"]["workflow"]["nullable"]
      refute result["properties"]["child_run_id"]["nullable"]

      assert request["properties"]["started_at"]["pattern"] ==
               WorkflowRunParts.started_at_pattern()
    end

    test "minimal, full and both golden fixtures match the request schema" do
      spec = ApiSpec.spec()

      assert_schema(minimal(), "WorkflowRunRequest", spec)
      assert_schema(full(), "WorkflowRunRequest", spec)

      for name <- ~w(parent-default child-suite) do
        {:ok, decoded} = golden_json(name) |> JsonDocument.decode()
        {:ok, document} = JsonDocument.normalize(decoded)
        assert_schema(document, "WorkflowRunRequest", spec)
      end
    end

    test "the request schema rejects null optional keys and an empty envelope" do
      spec = ApiSpec.spec()
      schema = spec.components.schemas["WorkflowRunRequest"]

      assert {:error, _} =
               OpenApiSpex.cast_value(Map.put(minimal(), "environment", nil), schema, spec)

      for key <- ~w(graph ci) do
        assert {:error, _} = OpenApiSpex.cast_value(Map.put(minimal(), key, nil), schema, spec)
        assert {:error, _} = OpenApiSpex.cast_value(Map.put(minimal(), key, %{}), schema, spec)
      end
    end

    test "the API description documents upload, idempotency, redaction and the soft link", %{
      doc: doc
    } do
      description = doc["info"]["description"]

      assert description =~ "## Workflow runs"
      assert description =~ "POST /api/v1/projects/{project}/workflow-runs"
      assert description =~ "exact retry"
      assert description =~ "duplicate: true"
      assert description =~ "each result's `command`"

      assert String.replace(description, ~r/\s+/, " ") =~
               "each graph job's and step's `command` and condition `text`, as null"

      assert description =~ "no foreign key"
      assert description =~ "4,194,304 bytes"
      assert description =~ "graph_sha256"
      assert description =~ "`source.branch`"
    end
  end

  test "serves Swagger UI", %{conn: conn} do
    assert conn |> get(~p"/api/v1/docs") |> html_response(200) =~ "/api/v1/openapi"
  end

  describe "caches" do
    setup %{conn: conn} do
      %{doc: conn |> get(~p"/api/v1/openapi") |> json_response(200)}
    end

    test "documents the cache section of the description", %{doc: doc} do
      description = doc["info"]["description"]

      assert description =~ "## Caches"
      assert description =~ "Never send your\n`Authorization` header"
      assert description =~ "opaque label"
      assert description =~ "`ck_…`"
      assert description =~ "`507`"
      assert description =~ "**Multipart saves.**"
      assert description =~ "no\n        `Authorization`" or description =~ "no\n`Authorization`"
      assert description =~ "restoring clients must check it"
    end

    test "documents parts on reserve and upload_parts in the reservation", %{doc: doc} do
      schemas = doc["components"]["schemas"]
      request = schemas["CacheReservationRequest"]
      assert "parts" in Map.keys(request["properties"])
      refute "parts" in request["required"]
      assert schemas["CacheUploadParts"]["additionalProperties"] == false
      assert schemas["CacheUploadParts"]["properties"]["size"]["minimum"] == 5_242_880

      data = schemas["CacheReservationResponse"]["properties"]["data"]
      assert data["properties"]["upload_parts"]["items"]["$ref"] =~ "CacheUploadPart"
      assert data["properties"]["upload_url"]["description"] =~ "without `parts`"
      assert data["properties"]["upload_headers"]["description"] =~ "without `parts`"
      refute "upload_url" in data["required"]
    end

    test "defines the cache schemas", %{doc: doc} do
      for name <-
            ~w(CacheEntry CacheEntryResponse CacheReservationRequest CacheReservationResponse
               CacheListResponse CachePurgeResponse CacheKeyRequest CacheKeyResponse
               CacheKeyListResponse ProjectUpdateRequest CacheUploadParts CacheUploadPart) do
        assert doc["components"]["schemas"][name], "missing schema #{name}"
      end

      assert doc["components"]["schemas"]["CacheKeyRequest"]["additionalProperties"] == false
    end

    test "documents the cache responses and parameters", %{doc: doc} do
      paths = doc["paths"]
      reserve = paths["/api/v1/projects/{project}/caches/entries/{key}"]["post"]

      assert Enum.sort(Map.keys(reserve["responses"])) ==
               ~w(201 401 403 404 409 413 415 422 503 507)

      assert reserve["requestBody"]["content"]["application/json"]["schema"]["$ref"] =~
               "CacheReservationRequest"

      show = paths["/api/v1/projects/{project}/caches/entries/{key}"]["get"]
      names = Enum.map(show["parameters"], & &1["name"])
      assert "key" in names and "scope" in names
      assert Enum.sort(Map.keys(show["responses"])) == ~w(200 401 403 404 422 503)

      commit = paths["/api/v1/projects/{project}/caches/uploads/{upload_id}/commit"]["post"]
      assert "upload_id" in Enum.map(commit["parameters"], & &1["name"])
      assert Enum.sort(Map.keys(commit["responses"])) == ~w(200 401 403 404 422 503)

      purge = paths["/api/v1/projects/{project}/caches/entries/{key}"]["delete"]
      assert Enum.find(purge["parameters"], &(&1["name"] == "scope"))["required"]

      mint = paths["/api/v1/projects/{project}/cache-keys"]["post"]

      assert mint["responses"]["201"]["content"]["application/json"]["schema"]["$ref"] =~
               "CacheKeyResponse"
    end
  end

  describe "change requests and review policy" do
    setup %{conn: conn} do
      %{paths: conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")}
    end

    @cr "/api/v1/projects/{project}/change-requests"
    @rp "/api/v1/projects/{project}/review-policy"
    @vr "/api/v1/projects/{project}/verify-runs"
    @fi "/api/v1/projects/{project}/feature-index"

    @statuses [
      {@cr, "get", ~w(200 401 403 404 406 422)},
      {@cr, "post", ~w(201 400 401 403 404 406 413 415 422)},
      {@cr <> "/{number}", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/ready", "post", ~w(200 401 403 404 406 409 415 422)},
      {@cr <> "/{number}/draft", "post", ~w(200 401 403 404 406 409 415 422)},
      {@cr <> "/{number}/close", "post", ~w(200 401 403 404 406 409 415 422)},
      {@cr <> "/{number}/reopen", "post", ~w(200 401 403 404 406 409 415 422)},
      {@cr <> "/{number}/merged", "post", ~w(200 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/git-facts", "post", ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/git-facts/{head}", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/claims", "post", ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/claims/{head}", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/verdict", "get", ~w(200 401 403 404 406 422)},
      {@rp, "get", ~w(200 401 403 404 406 422)},
      {@rp, "put", ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {@rp <> "/versions", "get", ~w(200 401 403 404 406 422)},
      {@rp <> "/versions/{version}", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/scenario-sets", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/scenario-sets", "post", ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/scenario-sets/{source}/versions/{version}", "get",
       ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/scenario-sets/{source}/compare", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/scenario-sets/{source}/approvals", "post",
       ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/scenario-sets/{source}/rejections", "post",
       ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {@vr, "get", ~w(200 401 403 404 406 422)},
      {@vr, "post", ~w(200 201 400 401 403 404 406 409 413 415 422 503)},
      {@vr <> "/{run_id}", "get", ~w(200 401 403 404 406 422)},
      {@vr <> "/{run_id}/commit", "post", ~w(200 401 403 404 406 422 503)},
      {@fi, "get", ~w(200 401 403 404 406 422)},
      {@fi, "post", ~w(200 201 400 401 403 404 406 413 415 422)},
      {@fi <> "/versions", "get", ~w(200 401 403 404 406 422)},
      {@fi <> "/versions/{version}", "get", ~w(200 401 403 404 406 422)},
      {"/api/v1/projects/{project}/events", "get", ~w(200 401 403 404 406 410 422)},
      {@cr <> "/{number}/review", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/review/items/{item_id}/answers", "post",
       ~w(201 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/tasks", "get", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/tasks/{task_id}/done", "post", ~w(200 401 403 404 406 422)},
      {@cr <> "/{number}/parent", "put", ~w(200 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/parent", "delete", ~w(200 401 403 404 406 409 422)},
      {@cr <> "/{number}/retarget", "post", ~w(200 400 401 403 404 406 409 413 415 422)},
      {@cr <> "/{number}/merge-lease", "post", ~w(200 201 400 401 403 404 406 409 413 415 422)},
      {"/api/v1/projects/{project}/merge-leases/{lease_id}/heartbeat", "post",
       ~w(200 401 403 404 406 409 422)},
      {"/api/v1/projects/{project}/merge-leases/{lease_id}", "delete",
       ~w(204 401 403 404 406 409 422)},
      {"/api/v1/projects/{project}/defects", "post", ~w(201 400 401 403 404 406 413 415 422)},
      {"/api/v1/projects/{project}/defects", "get", ~w(200 401 403 404 406 422)},
      {"/api/v1/projects/{project}/calibration", "get", ~w(200 401 403 404 406 422)}
    ]

    test "every operation lists its statuses", %{paths: paths} do
      for {path, verb, statuses} <- @statuses do
        responses = get_in(paths, [path, verb, "responses"])
        assert responses, "#{verb} #{path} is missing"
        assert Enum.sort(Map.keys(responses)) == Enum.sort(statuses), "#{verb} #{path}"
      end
    end

    test "request bodies: JSON documents and Markdown claims", %{paths: paths} do
      for {path, verb, schema} <- [
            {@cr, "post", "ChangeRequestCreateRequest"},
            {@cr <> "/{number}/merged", "post", "ChangeRequestMergeRequest"},
            {@cr <> "/{number}/git-facts", "post", "GitFactsDocument"},
            {@rp, "put", "ReviewPolicyWriteRequest"},
            {@cr <> "/{number}/scenario-sets", "post", "ScenarioSetUploadRequest"},
            {@cr <> "/{number}/scenario-sets/{source}/approvals", "post",
             "ScenarioSetDecisionRequest"},
            {@vr, "post", "VerifyRunRequest"},
            {@fi, "post", "FeatureIndexSyncRequest"},
            {@cr <> "/{number}/review/items/{item_id}/answers", "post", "ReviewAnswerRequest"},
            {@cr <> "/{number}/parent", "put", "ChangeRequestParentRequest"},
            {@cr <> "/{number}/retarget", "post", "ChangeRequestRetargetRequest"},
            {@cr <> "/{number}/merge-lease", "post", "MergeLeaseRequest"},
            {"/api/v1/projects/{project}/defects", "post", "DefectRequest"}
          ] do
        assert get_in(paths, [
                 path,
                 verb,
                 "requestBody",
                 "content",
                 "application/json",
                 "schema",
                 "$ref"
               ]) =~
                 schema
      end

      claims = get_in(paths, [@cr <> "/{number}/claims", "post", "requestBody", "content"])
      assert Map.keys(claims) == ["text/markdown"]
    end

    test "the event feed documents its parameters, types and 410 body", %{conn: conn} do
      doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)
      op = doc["paths"]["/api/v1/projects/{project}/events"]["get"]
      names = Enum.map(op["parameters"], & &1["name"])
      assert Enum.sort(names) == ~w(after limit project wait)

      assert get_in(op, ["responses", "410", "content", "application/json", "schema", "$ref"]) =~
               "EventsGoneResponse"

      schemas = doc["components"]["schemas"]
      assert Map.has_key?(schemas["EventsGoneResponse"]["properties"], "latest_cursor")

      assert Enum.sort(schemas["ProjectEvent"]["properties"]["type"]["enum"]) ==
               Enum.sort(ProjectEvents.types())

      for type <- ProjectEvents.types(),
          do: assert(schemas["ProjectEvent"]["description"] =~ "`#{type}`")
    end

    test "the review schemas list every item kind and answer kind", %{conn: conn} do
      schemas =
        conn
        |> get(~p"/api/v1/openapi")
        |> json_response(200)
        |> get_in(["components", "schemas"])

      assert Enum.sort(schemas["ReviewItem"]["properties"]["kind"]["enum"]) ==
               Enum.sort(Items.kinds())

      for kind <- Items.kinds(),
          do: assert(schemas["ReviewItem"]["description"] =~ "`#{kind}`")

      assert schemas["ReviewAnswerRequest"]["properties"]["answer"]["enum"] ==
               ~w(approve reject request_change choose)

      assert Map.has_key?(schemas["Verdict"]["properties"], "review")
    end

    test "merge coordination and calibration schemas", %{conn: conn} do
      doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)
      schemas = doc["components"]["schemas"]

      conflict =
        get_in(doc, [
          "paths",
          @cr <> "/{number}/merge-lease",
          "post",
          "responses",
          "409",
          "content",
          "application/json",
          "schema",
          "$ref"
        ])

      assert conflict =~ "CodedConflictResponse"
      errors = schemas["CodedConflictResponse"]["properties"]["errors"]

      assert Enum.sort(errors["properties"]["error"]["enum"]) ==
               Enum.sort(~w(not_open stale_head not_mergeable slot_taken lease_not_active
                 not_editable parent_not_merged lease_held))

      assert Map.keys(errors["properties"]["holder"]["properties"]) ==
               ["change_request", "expires_at"]

      assert Map.has_key?(schemas["ChangeRequestMergeRequest"]["properties"], "lease_id")
      refute "lease_id" in schemas["ChangeRequestMergeRequest"]["required"]
      assert "merged_without_lease" in schemas["ChangeRequestMerge"]["required"]
      assert "parent" in schemas["ChangeRequest"]["required"]

      assert schemas["DefectRequest"]["properties"]["severity"]["enum"] ==
               ~w(low medium high critical)

      assert schemas["Defect"]["properties"]["attribution"]["enum"] ==
               ~w(change_request commit unattributed)

      assert Enum.sort(Map.keys(schemas["CalibrationLanes"]["properties"])) ==
               ~w(auto bypass reviewed)

      assert "unmatched_defect_count" in get_in(schemas, [
               "CalibrationResponse",
               "properties",
               "data",
               "required"
             ])

      types = schemas["ProjectEvent"]["properties"]["type"]["enum"]
      assert "lease_expired" in types and "defect_recorded" in types

      rules = schemas["VerdictReason"]["properties"]["rule"]["enum"]

      for rule <- ~w(parent_not_merged parent_closed merge_result_ungraded merge_result_failed),
          do: assert(rule in rules)
    end

    test "the project delete 409 names change requests and verify runs", %{conn: conn} do
      doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)
      conflict = doc["paths"]["/api/v1/projects/{project}"]["delete"]["responses"]["409"]
      assert conflict["description"] =~ "change requests"
      assert conflict["description"] =~ "verify runs"
    end
  end
end
