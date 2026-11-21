defmodule GoodFlowsWeb.Schemas.ScenarioSetDecisionRequest do
  @moduledoc "OpenAPI schema: An approval (`digest`) or rejection (`digest` and a `note` of 1 to 10,000 bytes)."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetDecisionRequest",
    description:
      "An approval (`digest`) or rejection (`digest` and a `note` of 1 to 10,000 bytes).",
    type: :object,
    required: [:digest],
    additionalProperties: false,
    properties: %{
      digest: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"},
      note: %Schema{type: :string, minLength: 1, description: "Required on rejections only"}
    }
  })
end
