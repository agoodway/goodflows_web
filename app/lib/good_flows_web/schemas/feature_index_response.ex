defmodule GoodFlowsWeb.Schemas.FeatureIndexResponse do
  @moduledoc "OpenAPI schema: One feature index version."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "FeatureIndexResponse",
    description: "One feature index version.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:version, :inserted_at, :features],
        properties: %{
          version: %Schema{type: :integer, minimum: 1},
          inserted_at: %Schema{type: :string, format: :"date-time"},
          features: %Schema{type: :array, items: %Schema{type: :object}},
          duplicate: %Schema{type: :boolean}
        }
      }
    }
  })
end
