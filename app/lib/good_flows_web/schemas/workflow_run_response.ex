defmodule GoodFlowsWeb.Schemas.WorkflowRunResponse do
  @moduledoc """
  OpenAPI schema for one stored workflow run: the document, its server id,
  and the test reports linked by `workflow_run_id`.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.WorkflowRunParts
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
          document: %{
            WorkflowRunParts.shown_document()
            | description:
                "The stored upload. A public key receives every `command` and condition " <>
                  "`text` as null, and `links.threads` as null when the run has threads."
          },
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
    `error` set to null, each `graph` job's and step's `command` and
    condition `text` set to null, and `links.threads` set to null when the
    document has it (a `links` without threads gains no `threads` key;
    `links.tickets` is as stored). The stored row is unchanged.
    """
  })
end
