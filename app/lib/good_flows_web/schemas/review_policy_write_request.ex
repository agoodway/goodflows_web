defmodule GoodFlowsWeb.Schemas.ReviewPolicyWriteRequest do
  @moduledoc "OpenAPI schema for writing a review policy version."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewPolicyWriteRequest",
    type: :object,
    additionalProperties: false,
    required: [:previous_version, :policy],
    properties: %{
      previous_version: %Schema{
        type: :integer,
        minimum: 0,
        description: "The current version; anything else is `409`"
      },
      policy: GoodFlowsWeb.Schemas.ReviewPolicyDocument,
      note: %Schema{type: :string, minLength: 1, maxLength: 1024}
    }
  })
end
