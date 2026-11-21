defmodule GoodFlowsWeb.Schemas.VerifyRunAcknowledgement do
  @moduledoc "OpenAPI schema: A stored verify run and, while it is `uploading`, one presigned PUT per artifact."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerifyRunAcknowledgement",
    description:
      "A stored verify run and, while it is `uploading`, one presigned PUT per artifact. Presigned URLs are bearer credentials.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:id, :run_id, :status, :duplicate, :expires_at, :uploads],
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          run_id: %Schema{type: :string, format: :uuid},
          status: %Schema{type: :string, enum: ~w(uploading final)},
          duplicate: %Schema{type: :boolean},
          expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
          uploads: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                artifact_id: %Schema{type: :string},
                upload_url: %Schema{type: :string},
                upload_headers: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :string}
                },
                upload_url_expires_at: %Schema{type: :string, format: :"date-time"}
              }
            }
          }
        }
      }
    }
  })
end
