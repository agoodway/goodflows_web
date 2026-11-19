defmodule GoodFlowsWeb.Schemas.CacheReservationResponse do
  @moduledoc "OpenAPI schema for a cache reservation."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.CacheUploadPart
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheReservationResponse",
    description: """
    PUT the archive to `upload_url` with exactly `upload_headers` and no
    `Authorization` header before `upload_url_expires_at`, then commit
    `upload_id` before `expires_at`. The headers are signed into the URL,
    so the object store rejects a body whose length or SHA-256 differs.

    A reservation made with `parts` has `upload_parts` instead of
    `upload_url` and `upload_headers`: PUT every part (in any order, in
    parallel if you like) before `upload_url_expires_at`, which for parts is
    the reservation's lifetime, then commit.
    """,
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:upload_id, :upload_url_expires_at, :expires_at],
        properties: %{
          upload_id: %Schema{type: :string, format: :uuid},
          upload_url: %Schema{
            type: :string,
            format: :uri,
            description: "Only in a reservation without `parts`."
          },
          upload_parts: %Schema{
            type: :array,
            items: CacheUploadPart,
            description: "Only in a reservation with `parts`: one entry per part, in order."
          },
          upload_headers: %Schema{
            type: :object,
            description: "Only in a reservation without `parts`.",
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
