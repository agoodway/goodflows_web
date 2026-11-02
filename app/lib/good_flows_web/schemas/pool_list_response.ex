defmodule GoodFlowsWeb.Schemas.PoolListResponse do
  @moduledoc "OpenAPI schema for a list of pools."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PoolListResponse",
    type: :object,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.Pool}}
  })
end
