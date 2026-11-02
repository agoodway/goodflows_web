defmodule GoodFlowsWeb.Schemas.SpritesCredentialRequest do
  @moduledoc "OpenAPI schema for setting the Sprites credential."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SpritesCredentialRequest",
    type: :object,
    required: [:token],
    properties: %{
      token: %Schema{
        type: :string,
        minLength: 1,
        writeOnly: true,
        description: "Sprites API token. Stored encrypted and never returned."
      }
    },
    example: %{"token" => "sprites_xxxxxxxxxxxxa1b2"}
  })
end
