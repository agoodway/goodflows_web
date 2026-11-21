defmodule GoodFlowsWeb.Schemas.DefectResponse do
  @moduledoc "OpenAPI schema for one defect."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DefectResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.Defect}
  })
end
