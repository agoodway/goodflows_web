defmodule GoodFlowsWeb.Schemas.TestReportAcknowledgement do
  @moduledoc "OpenAPI schema for a test report storage acknowledgement (`201` or `200`)."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TestReportAcknowledgement",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:id, :report_id, :status, :duplicate],
        additionalProperties: false,
        properties: %{
          id: %Schema{type: :string, format: :uuid, description: "Stable server id"},
          report_id: %Schema{type: :string, description: "The report's `report.report_id`"},
          status: %Schema{
            type: :string,
            enum: ["complete", "incomplete"],
            description: "Per-report completion; not a test result"
          },
          duplicate: %Schema{
            type: :boolean,
            description: "`true` when this request was an exact retry of a stored report"
          }
        }
      }
    },
    example: %{
      "data" => %{
        "id" => "8c1f0b8e-4a35-4d1e-9a6c-2f0d5b7e9a31",
        "report_id" => "report-1",
        "status" => "complete",
        "duplicate" => false
      }
    }
  })
end
