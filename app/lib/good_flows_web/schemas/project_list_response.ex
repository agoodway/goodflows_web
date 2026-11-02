defmodule GoodFlowsWeb.Schemas.ProjectListResponse do
  @moduledoc "OpenAPI schema for the project list."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProjectListResponse",
    type: :object,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.Project}}
  })
end
