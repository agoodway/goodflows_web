defmodule GoodFlowsWeb.Schemas.ConflictResponse do
  @moduledoc "OpenAPI schema for `409 Conflict` when deleting a recipe that has an active run."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ConflictResponse",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail],
        properties: %{detail: %Schema{type: :string}}
      }
    },
    example: %{"errors" => %{"detail" => "The recipe has a queued or running run"}}
  })
end
