defmodule GoodFlowsWeb.Schemas.PoolSessionRequest do
  @moduledoc "OpenAPI schema for creating a pool session."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PoolSessionRequest",
    description: """
    `max_members` (1 to the pool's `max_members`) is the most members the
    session will hold; members are granted one at a time as they become
    idle. `acquire_timeout_ms` (1,000 to the server maximum, 10 minutes by
    default) bounds the wait for the first member. Any other key is `422`.
    """,
    type: :object,
    required: [:max_members, :acquire_timeout_ms],
    additionalProperties: false,
    properties: %{
      max_members: %Schema{type: :integer, minimum: 1},
      acquire_timeout_ms: %Schema{type: :integer, minimum: 1_000},
      label: %Schema{type: :string, maxLength: 255, description: "No control characters"}
    },
    example: %{"max_members" => 4, "acquire_timeout_ms" => 120_000, "label" => "goodci"}
  })
end
