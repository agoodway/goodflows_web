defmodule GoodFlowsWeb.Schemas.PoolSessionResponse do
  @moduledoc "OpenAPI schema for a single pool session response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PoolSessionResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.PoolSession}
  })
end
