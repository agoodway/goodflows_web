defmodule GoodFlowsWeb.Schemas.ChangeRequestParentRequest do
  @moduledoc "OpenAPI schema for setting a change request's parent."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequestParentRequest",
    type: :object,
    additionalProperties: false,
    required: [:number],
    properties: %{
      number: %Schema{
        type: :integer,
        minimum: 1,
        description: "A lower change request number of the same project"
      }
    }
  })
end
