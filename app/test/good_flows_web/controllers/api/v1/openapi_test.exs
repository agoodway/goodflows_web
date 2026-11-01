defmodule GoodFlowsWeb.Api.V1.OpenApiTest do
  use GoodFlowsWeb.ConnCase, async: true

  test "serves the OpenAPI spec", %{conn: conn} do
    spec = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    assert spec["info"]["title"] == "GoodFlows API"
    assert spec["paths"]["/api/v1/me"]["get"]["operationId"]
    assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
  end

  test "serves Swagger UI", %{conn: conn} do
    assert conn |> get(~p"/api/v1/docs") |> html_response(200) =~ "/api/v1/openapi"
  end
end
