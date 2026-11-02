defmodule GoodFlowsWeb.Schemas.RunResponse do
  @moduledoc "OpenAPI schema for a single-run response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RunResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.Run}
  })
end
