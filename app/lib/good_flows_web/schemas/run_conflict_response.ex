defmodule GoodFlowsWeb.Schemas.RunConflictResponse do
  @moduledoc "OpenAPI schema for `409 Conflict` when a run is already active for the sprite."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RunConflictResponse",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail, :active_run_id],
        properties: %{
          detail: %Schema{type: :string},
          active_run_id: %Schema{
            type: :string,
            format: :uuid,
            description: "The queued or running run that blocks the request (never null)"
          }
        }
      }
    },
    example: %{
      "errors" => %{
        "detail" => "A run is already queued or running for this sprite",
        "active_run_id" => "0b7e2c1d-3f4a-4b5c-8d6e-7f8091a2b3c4"
      }
    }
  })
end
