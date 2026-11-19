defmodule GoodFlowsWeb.Schemas.CacheKeyRequest do
  @moduledoc "OpenAPI schema for minting a cache key."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheKeyRequest",
    description: """
    `access` is `read` or `read_write`. `scope` binds the key: a bound key
    reads only that scope and the default-branch scope, and a bound
    `read_write` key writes only that scope. Omitting `ttl_seconds` gives
    21,600 seconds. `read_write` keys take 60 to 86,400 seconds. `read`
    keys take 60 to 31,536,000 seconds, or `null` for no expiry, which
    requires `name`. No other key is allowed (`422`).
    """,
    type: :object,
    required: [:access],
    additionalProperties: false,
    properties: %{
      access: %Schema{type: :string, enum: ["read", "read_write"]},
      scope: %Schema{type: :string, minLength: 1},
      ttl_seconds: %Schema{type: :integer, minimum: 60, maximum: 31_536_000, nullable: true},
      name: %Schema{type: :string, maxLength: 100}
    },
    example: %{"access" => "read_write", "scope" => "feature/login", "ttl_seconds" => 3600}
  })
end
