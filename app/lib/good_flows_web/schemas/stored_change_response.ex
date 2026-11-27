defmodule GoodFlowsWeb.Schemas.StoredChangeResponse do
  @moduledoc "OpenAPI schema: A stored change's latest version with its files and linked change requests."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.{StoredChangeFile, StoredChangeLink, StoredChangeVersion}
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeResponse",
    description: "A stored change's latest version with its files and linked change requests.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: StoredChangeVersion.required() ++ [:files, :change_requests],
        properties:
          Map.merge(StoredChangeVersion.properties(), %{
            files: %Schema{type: :array, items: StoredChangeFile},
            change_requests: %Schema{type: :array, items: StoredChangeLink}
          })
      }
    }
  })
end
