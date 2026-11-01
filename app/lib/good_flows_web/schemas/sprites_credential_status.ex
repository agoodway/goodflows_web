defmodule GoodFlowsWeb.Schemas.SpritesCredentialStatus do
  @moduledoc "OpenAPI schema for the Sprites credential status. It never includes the token."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SpritesCredentialStatus",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:configured, :last4, :updated_at],
        additionalProperties: false,
        properties: %{
          configured: %Schema{type: :boolean},
          last4: %Schema{
            type: :string,
            nullable: true,
            description: "Last four token characters; null for tokens of four or fewer characters"
          },
          updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
        }
      }
    },
    example: %{
      "data" => %{
        "configured" => true,
        "last4" => "a1b2",
        "updated_at" => "2026-11-01T12:00:00.000000Z"
      }
    }
  })
end
