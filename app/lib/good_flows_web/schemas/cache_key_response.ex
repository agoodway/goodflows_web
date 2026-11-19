defmodule GoodFlowsWeb.Schemas.CacheKeyResponse do
  @moduledoc "OpenAPI schema for a minted cache key. The token is shown only here."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheKeyResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:id, :token, :access, :scope, :expires_at],
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          token: %Schema{type: :string, description: "Starts with `ck_`; never shown again"},
          access: %Schema{type: :string, enum: ["read", "read_write"]},
          scope: %Schema{type: :string, nullable: true},
          expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
        }
      }
    }
  })
end
