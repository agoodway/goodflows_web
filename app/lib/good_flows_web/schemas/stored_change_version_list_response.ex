defmodule GoodFlowsWeb.Schemas.StoredChangeVersionListResponse do
  @moduledoc "OpenAPI schema: one page of a stored change's versions."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.StoredChangeVersion
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeVersionListResponse",
    description:
      "Versions newest first, without files; `latest` is true only for the latest. " <>
        "Public keys see only `version`, `status`, `pushed_at`, `source`, `latest` and " <>
        "`pushed_by` null; `change_id`, `size`, `door`, `capabilities` and `depends_on` " <>
        "are for private keys.",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: [:version, :status, :pushed_at, :source, :pushed_by, :latest],
          properties: Map.put(StoredChangeVersion.properties(), :latest, %Schema{type: :boolean})
        }
      },
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
