defmodule GoodFlowsWeb.Api.V1.OpenApiTest do
  use GoodFlowsWeb.ConnCase, async: true

  alias GoodFlows.Projects.Project

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
    {"/api/v1/projects/{project}/workflow-runs/{run_id}", "get"}
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
end
