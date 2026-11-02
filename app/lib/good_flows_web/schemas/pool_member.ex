defmodule GoodFlowsWeb.Schemas.PoolMember do
  @moduledoc "OpenAPI schema for a pool member."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PoolMember",
    description: """
    One Sprite VM of a pool. `name` is server-chosen (`gfp-…`). `stale` is
    true when the member was built from an older `setup_version` or with a
    different transfer helper; stale members are never granted and are
    destroyed after their current lease. `session_id` is the leasing
    session, or null.
    """,
    type: :object,
    required: [
      :id,
      :name,
      :state,
      :setup_version,
      :stale,
      :session_id,
      :last_error,
      :inserted_at,
      :updated_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string, pattern: "^gfp-[a-z0-9-]+$"},
      state: %Schema{
        type: :string,
        enum: [
          "provisioning",
          "idle",
          "leased",
          "resetting",
          "broken",
          "destroying",
          "abandoned"
        ],
        description:
          "`abandoned`: the sprite could not be destroyed with its creation credential " <>
            "(revoked); it is no longer retried and is forgotten when the pool is deleted"
      },
      setup_version: %Schema{type: :integer},
      stale: %Schema{type: :boolean},
      session_id: %Schema{type: :string, format: :uuid, nullable: true},
      last_error: %Schema{type: :string, nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
