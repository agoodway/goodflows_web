defmodule GoodFlowsWeb.Schemas.DefectListResponse do
  @moduledoc "OpenAPI schema for one page of defects, newest first."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DefectListResponse",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.Defect},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
