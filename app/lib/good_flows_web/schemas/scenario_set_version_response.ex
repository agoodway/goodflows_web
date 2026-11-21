defmodule GoodFlowsWeb.Schemas.ScenarioSetVersionResponse do
  @moduledoc "OpenAPI schema: One scenario set version."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ScenarioSetVersionResponse",
    description: "One scenario set version.",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.ScenarioSetVersion}
  })
end
