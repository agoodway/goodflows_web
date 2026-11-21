defmodule GoodFlowsWeb.Schemas.FeatureIndexSyncRequest do
  @moduledoc "OpenAPI schema: Every feature of the verify skill, with path globs."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "FeatureIndexSyncRequest",
    description: "Every feature of the verify skill, with path globs.",
    type: :object,
    required: [:features],
    additionalProperties: false,
    properties: %{
      features: %Schema{
        type: :array,
        minItems: 1,
        maxItems: 500,
        items: %Schema{
          type: :object,
          required: [:id, :title, :paths],
          additionalProperties: false,
          properties: %{
            id: %Schema{type: :string, pattern: "^[a-z0-9][a-z0-9_-]{0,63}$"},
            title: %Schema{type: :string, minLength: 1, maxLength: 200},
            paths: %Schema{
              type: :array,
              minItems: 1,
              maxItems: 100,
              items: %Schema{type: :string, minLength: 1, maxLength: 512}
            }
          }
        }
      }
    }
  })
end
