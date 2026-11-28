defmodule GoodFlowsWeb.Schemas.StoredChangeVersionResponse do
  @moduledoc "OpenAPI schema: One version with its files, its own status and the change's latest_status."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.{StoredChangeFile, StoredChangeVersion}
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeVersionResponse",
    description: "One version with its files, its own status and the change's latest_status.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: StoredChangeVersion.required() ++ [:files, :latest_status],
        properties:
          Map.merge(StoredChangeVersion.properties(), %{
            files: %Schema{type: :array, items: StoredChangeFile},
            latest_status: %Schema{type: :string, enum: ~w(proposed approved archived)}
          })
      }
    }
  })
end
