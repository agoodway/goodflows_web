defmodule GoodFlowsWeb.Schemas.ClaimsResponse do
  @moduledoc """
  OpenAPI schema for a claims read. Public keys see `document` as null and
  only `format`, `cr`, `head` and `door` in `front_matter`.
  """
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ClaimsResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:head, :document, :front_matter, :user_id, :inserted_at],
        properties: %{
          head: %Schema{type: :string},
          document: %Schema{type: :string, nullable: true, description: "The raw file"},
          front_matter: %Schema{type: :object, description: "The parsed YAML front matter"},
          user_id: %Schema{type: :string, format: :uuid, nullable: true},
          inserted_at: %Schema{type: :string, format: :"date-time"}
        }
      }
    }
  })
end
