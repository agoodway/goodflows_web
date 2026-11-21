defmodule GoodFlowsWeb.Schemas.CalibrationStats do
  @moduledoc "OpenAPI schema for merge and defect counts of one calibration lane."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CalibrationStats",
    type: :object,
    required: [:merged_count, :defect_count, :defective_count, :defect_rate],
    properties: %{
      merged_count: %Schema{type: :integer, minimum: 0},
      defect_count: %Schema{type: :integer, minimum: 0},
      defective_count: %Schema{
        type: :integer,
        minimum: 0,
        description: "Merged change requests with at least one defect"
      },
      defect_rate: %Schema{
        type: :number,
        nullable: true,
        description: "`defective_count / merged_count`, null when `merged_count` is 0"
      }
    }
  })
end
