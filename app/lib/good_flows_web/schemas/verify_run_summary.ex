defmodule GoodFlowsWeb.Schemas.VerifyRunSummary do
  @moduledoc "OpenAPI schema: A verify run summary."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerifyRunSummary",
    description: "A verify run summary.",
    type: :object,
    required: [:id, :run_id, :status, :started_at, :finished_at, :source, :scenario_set, :counts],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      run_id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: ~w(uploading final)},
      started_at: %Schema{type: :string},
      finished_at: %Schema{type: :string},
      source: %Schema{
        type: :object,
        properties: %{
          commit: %Schema{type: :string},
          branch: %Schema{type: :string, nullable: true},
          dirty: %Schema{type: :boolean}
        }
      },
      scenario_set: %Schema{
        type: :object,
        properties: %{digest: %Schema{type: :string}, source: %Schema{type: :string}}
      },
      counts: %Schema{
        type: :object,
        properties: %{
          passed: %Schema{type: :integer},
          failed: %Schema{type: :integer},
          not_run: %Schema{type: :integer}
        }
      }
    }
  })
end
