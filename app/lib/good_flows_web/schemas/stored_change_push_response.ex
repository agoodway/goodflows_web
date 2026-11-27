defmodule GoodFlowsWeb.Schemas.StoredChangePushResponse do
  @moduledoc "OpenAPI schema: The version a push stored (201) or the unchanged latest version (200, duplicate true)."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.StoredChangeVersion
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangePushResponse",
    description:
      "The version a push stored (201) or the unchanged latest version (200, duplicate true).",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: StoredChangeVersion.required() ++ [:duplicate, :replaced_version],
        properties:
          Map.merge(StoredChangeVersion.properties(), %{
            duplicate: %Schema{type: :boolean},
            replaced_version: %Schema{
              type: :integer,
              nullable: true,
              description:
                "The version that was latest before the push: null for a new change, the latest version for a duplicate"
            }
          })
      }
    }
  })
end
