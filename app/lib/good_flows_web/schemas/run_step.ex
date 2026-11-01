defmodule GoodFlowsWeb.Schemas.RunStep do
  @moduledoc """
  OpenAPI schema for one step of a run. `command` and `output` are present
  only for private (`sk_`) keys.
  """
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RunStep",
    type: :object,
    required: [:index, :kind, :status],
    properties: %{
      index: %Schema{type: :integer},
      kind: %Schema{type: :string, enum: ["create", "exec", "destroy"]},
      command: %Schema{
        type: :string,
        description: "The expanded command. Omitted for public (`pk_`) keys."
      },
      status: %Schema{
        type: :string,
        enum: ["pending", "running", "succeeded", "failed", "skipped"]
      },
      exit_code: %Schema{type: :integer, nullable: true},
      reason: %Schema{
        type: :string,
        nullable: true,
        description: "Failure reason, e.g. `timeout` or `run_timeout`"
      },
      output: %Schema{
        type: :string,
        nullable: true,
        description:
          "Combined stdout/stderr tail (last 64 KiB). Omitted for public (`pk_`) keys; " <>
            "null before the step finishes and after the output retention period"
      },
      output_truncated: %Schema{type: :boolean},
      started_at: %Schema{type: :string, format: :"date-time", nullable: true},
      finished_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end
