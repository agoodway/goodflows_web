defmodule GoodFlowsWeb.Schemas.VerifyRunResponse do
  @moduledoc "OpenAPI schema: One verify run."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerifyRunResponse",
    description:
      "One verify run. Public keys see results' `reason` and `failed_step`, features' `entry_point`, `source.changed_files` and `links.threads` as null, and no artifact URLs.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:id, :run_id, :status, :inserted_at, :document, :artifacts],
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          run_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string, enum: ~w(uploading final)},
          inserted_at: %Schema{type: :string, format: :"date-time"},
          document: %Schema{type: :object},
          artifacts: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              required: [:id, :expired],
              properties: %{
                id: %Schema{type: :string},
                expired: %Schema{type: :boolean},
                download_url: %Schema{type: :string},
                download_url_expires_at: %Schema{type: :string, format: :"date-time"}
              }
            }
          }
        }
      }
    }
  })
end
