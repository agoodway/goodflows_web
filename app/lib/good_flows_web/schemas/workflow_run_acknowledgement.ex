defmodule GoodFlowsWeb.Schemas.WorkflowRunAcknowledgement do
  @moduledoc """
  OpenAPI schema for a workflow-run storage acknowledgement (`201` or `200`).
  The stored document is not returned.
  """
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "WorkflowRunAcknowledgement",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:id, :run_id, :duplicate],
        additionalProperties: false,
        properties: %{
          id: %Schema{type: :string, format: :uuid, description: "Stable server id"},
          run_id: %Schema{
            type: :string,
            format: :uuid,
            description: "The document's `run_id`"
          },
          duplicate: %Schema{
            type: :boolean,
            description: "`true` when this request was an exact retry of the stored run"
          }
        }
      }
    },
    example: %{
      "data" => %{
        "id" => "8c1f0b8e-4a35-4d1e-9a6c-2f0d5b7e9a31",
        "run_id" => "11111111-1111-4111-8111-111111111111",
        "duplicate" => false
      }
    }
  })
end
