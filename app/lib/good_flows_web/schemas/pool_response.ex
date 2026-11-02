defmodule GoodFlowsWeb.Schemas.PoolResponse do
  @moduledoc "OpenAPI schema for a single-pool response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PoolResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.Pool}
  })
end
