defmodule GoodFlowsWeb.Schemas.CacheKeyListResponse do
  @moduledoc "OpenAPI schema for a page of a project's active cache keys, without tokens."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheKeyListResponse",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: [
            :id,
            :name,
            :access,
            :scope,
            :token_prefix,
            :expires_at,
            :last_used_at,
            :inserted_at
          ],
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string},
            access: %Schema{type: :string, enum: ["read", "read_write"]},
            scope: %Schema{type: :string, nullable: true},
            token_prefix: %Schema{type: :string},
            expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
            last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
            inserted_at: %Schema{type: :string, format: :"date-time"}
          }
        }
      },
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
