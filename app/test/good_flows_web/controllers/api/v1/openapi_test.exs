defmodule GoodFlowsWeb.Api.V1.OpenApiTest do
  use GoodFlowsWeb.ConnCase, async: true

  alias GoodFlows.Projects.Project

  test "serves the OpenAPI spec", %{conn: conn} do
    spec = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    assert spec["info"]["title"] == "GoodFlows API"
    assert spec["paths"]["/api/v1/me"]["get"]["operationId"]
    assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
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
    {"/api/v1/projects/{project}/pools", "get"},
    {"/api/v1/projects/{project}/pools", "post"},
    {"/api/v1/projects/{project}/pools/{pool}", "get"},
    {"/api/v1/projects/{project}/pools/{pool}", "put"},
    {"/api/v1/projects/{project}/pools/{pool}", "delete"},
    {"/api/v1/projects/{project}/pools/{pool}/members", "get"},
    {"/api/v1/projects/{project}/pools/{pool}/sessions", "post"}
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

  test "serves Swagger UI", %{conn: conn} do
    assert conn |> get(~p"/api/v1/docs") |> html_response(200) =~ "/api/v1/openapi"
  end
end
