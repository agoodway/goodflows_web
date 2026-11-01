defmodule GoodFlowsWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3 specification for the `/api/v1` JSON API, built from the
  router's `open_api_operation` annotations. Served at `/api/v1/openapi`
  with Swagger UI at `/api/v1/docs`.
  """
  @behaviour OpenApiSpex.OpenApi

  alias GoodFlowsWeb.{Endpoint, Router}
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApi
  def spec do
    OpenApiSpex.resolve_schema_modules(%OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "GoodFlows API",
        version: "1.0.0",
        description: """
        ## Authentication

        Every endpoint requires an API key in the `Authorization` header:

            Authorization: Bearer <api_key>

        Create keys from the dashboard under **Developers → API Keys**.

        - **Public keys** (`pk_…`) are read-only.
        - **Private keys** (`sk_…`) can also write.

        A key is scoped to your membership in one account. To work with
        several accounts, create a key in each.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "API key",
            description: "`pk_…` (read-only) or `sk_…` (read-write)"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    })
  end
end
