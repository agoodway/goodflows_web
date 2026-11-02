defmodule GoodFlowsWeb.Schemas.ProjectResponse do
  @moduledoc "OpenAPI schema for a single-project response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ProjectResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.Project}
  })
end
