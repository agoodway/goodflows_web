defmodule GoodFlowsWeb.Schemas.ChangeRequestListResponse do
  @moduledoc "OpenAPI schema for one page of change requests."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequestListResponse",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.ChangeRequest},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
