defmodule GoodFlowsWeb.Schemas.CacheListResponse do
  @moduledoc "OpenAPI schema for a page of cache entries and the project's usage."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheListResponse",
    description: """
    Committed entries newest first, without download URLs. `usage` counts
    committed entries and unexpired reservations. Pass `next_cursor` as
    `cursor` for the next page; it is null on the last page.
    """,
    type: :object,
    required: [:data, :next_cursor, :usage],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.CacheEntry},
      next_cursor: %Schema{type: :string, nullable: true},
      usage: %Schema{
        type: :object,
        required: [:bytes, :entries, :quota_bytes, :max_entries],
        properties: %{
          bytes: %Schema{type: :integer},
          entries: %Schema{type: :integer},
          quota_bytes: %Schema{type: :integer},
          max_entries: %Schema{type: :integer}
        }
      }
    }
  })
end
