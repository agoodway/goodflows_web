defmodule GoodFlowsWeb.Schemas.PoolMemberListResponse do
  @moduledoc "OpenAPI schema for a pool's members."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PoolMemberListResponse",
    type: :object,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.PoolMember}}
  })
end
