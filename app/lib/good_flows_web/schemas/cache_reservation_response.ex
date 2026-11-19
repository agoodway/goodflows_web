defmodule GoodFlowsWeb.Schemas.CacheReservationResponse do
  @moduledoc "OpenAPI schema for a cache reservation."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheReservationResponse",
    description: """
    PUT the archive to `upload_url` with exactly `upload_headers` and no
    `Authorization` header before `upload_url_expires_at`, then commit
    `upload_id` before `expires_at`. The headers are signed into the URL,
    so the object store rejects a body whose length or SHA-256 differs.
    """,
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:upload_id, :upload_url, :upload_headers, :upload_url_expires_at, :expires_at],
        properties: %{
          upload_id: %Schema{type: :string, format: :uuid},
          upload_url: %Schema{type: :string, format: :uri},
          upload_headers: %Schema{
            type: :object,
            required: ["content-length", "content-type", "x-amz-checksum-sha256"],
            properties: %{
              "content-length" => %Schema{type: :string},
              "content-type" => %Schema{type: :string, enum: ["application/gzip"]},
              "x-amz-checksum-sha256" => %Schema{
                type: :string,
                description: "Base64 of the SHA-256 digest"
              }
            }
          },
          upload_url_expires_at: %Schema{type: :string, format: :"date-time"},
          expires_at: %Schema{type: :string, format: :"date-time"}
        }
      }
    }
  })
end
