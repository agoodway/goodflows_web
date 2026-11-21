defmodule GoodFlowsWeb.Schemas.FeatureIndexVersionListResponse do
  @moduledoc "OpenAPI schema: Feature index versions, newest first."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "FeatureIndexVersionListResponse",
    description: "Feature index versions, newest first.",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            version: %Schema{type: :integer},
            inserted_at: %Schema{type: :string, format: :"date-time"},
            feature_count: %Schema{type: :integer}
          }
        }
      },
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
