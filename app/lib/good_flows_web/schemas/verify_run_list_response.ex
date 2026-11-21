defmodule GoodFlowsWeb.Schemas.VerifyRunListResponse do
  @moduledoc "OpenAPI schema: One page of verify runs."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerifyRunListResponse",
    description: "One page of verify runs.",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.VerifyRunSummary},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
