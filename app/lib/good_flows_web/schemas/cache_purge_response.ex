defmodule GoodFlowsWeb.Schemas.CachePurgeResponse do
  @moduledoc "OpenAPI schema for a cache purge result."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CachePurgeResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:deleted],
        properties: %{
          deleted: %Schema{
            type: :integer,
            minimum: 0,
            description: "Entries and reservations deleted; `0` when nothing matched"
          }
        }
      }
    },
    example: %{"data" => %{"deleted" => 2}}
  })
end
