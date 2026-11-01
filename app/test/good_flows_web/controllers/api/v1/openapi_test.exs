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
    {"/api/v1/projects/{project}/recipes/{id}/runs", "post"}
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

  test "serves Swagger UI", %{conn: conn} do
    assert conn |> get(~p"/api/v1/docs") |> html_response(200) =~ "/api/v1/openapi"
  end
end
