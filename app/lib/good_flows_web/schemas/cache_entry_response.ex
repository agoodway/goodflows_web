defmodule GoodFlowsWeb.Schemas.CacheEntryResponse do
  @moduledoc "OpenAPI schema for a cache lookup or commit response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CacheEntryResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.CacheEntry}
  })
end
