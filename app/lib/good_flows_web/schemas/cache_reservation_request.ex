defmodule GoodFlowsWeb.Schemas.CacheReservationRequest do
  @moduledoc "OpenAPI schema for reserving a cache upload."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.{CacheEntry, CacheUploadParts}
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheReservationRequest",
    description: """
    Every field but `parts` is required and no other key is allowed (`422`). `scope` is
    an opaque label of 1 to 256 bytes with no control characters, not
    validated as a Git ref. `name` is the cache's declared name (1 to 64
    bytes, not blank, no control characters), metadata only. `size` is an
    integer from 1 through the entry cap (default 5,000,000,000); above it
    is `413`.

    `parts` (optional; `null` is the same as absent) asks for a multipart
    upload: the response then has `upload_parts` instead of `upload_url`.
    `sha256` is still required; for a multipart entry the store does not
    verify it, so restoring clients must check it.
    """,
    type: :object,
    required: [:name, :partial, :scope, :size, :sha256],
    additionalProperties: false,
    properties: %{
      name: %Schema{type: :string, minLength: 1},
      partial: CacheEntry.hex64(),
      scope: %Schema{type: :string, minLength: 1},
      size: %Schema{type: :integer, minimum: 1},
      sha256: CacheEntry.hex64(),
      parts: %Schema{allOf: [CacheUploadParts], nullable: true}
    },
    example: %{
      "name" => "deps",
      "partial" => String.duplicate("b", 64),
      "scope" => "feature/login",
      "size" => 52_428_800,
      "sha256" => String.duplicate("c", 64)
    }
  })
end
