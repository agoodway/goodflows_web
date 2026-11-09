defmodule GoodFlowsWeb.Schemas.WorkflowRunResponse do
  @moduledoc """
  OpenAPI schema for one stored workflow run: the document, its server id,
  and the test reports linked by `workflow_run_id`.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.{WorkflowRunParts, WorkflowRunRequest}
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "WorkflowRunResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        additionalProperties: false,
        required: [:id, :run_id, :inserted_at, :document, :test_reports],
        properties: %{
          id: %Schema{type: :string, format: :uuid, description: "Stable server id"},
          run_id: %Schema{type: :string, format: :uuid, description: "The document's `run_id`"},
          inserted_at: %Schema{type: :string, format: :"date-time"},
          document: WorkflowRunRequest,
          test_reports: %Schema{
            type: :array,
            items: WorkflowRunParts.report_summary(),
            description:
              "Test reports in this account and project whose `workflow_run_id` " <>
                "equals `run_id`, ordered by `job` then `report_id`. Empty when none are stored."
          }
        }
      }
    },
    description: """
    `document` equals the upload as a JSON value (key order is not preserved).
    A public (`pk_`) key receives each `results` entry with `command` and
    `error` set to null. The stored row is unchanged.
    """
  })
end
