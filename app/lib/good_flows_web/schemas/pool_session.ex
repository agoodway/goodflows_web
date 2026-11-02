defmodule GoodFlowsWeb.Schemas.PoolSession do
  @moduledoc "OpenAPI schema for a pool session."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PoolSession",
    description: """
    One client invocation's lease on members of a pool. `status` is
    `waiting` (no member yet), `active`, `released`, or `expired`;
    `end_reason` is set only when `expired` (`no_member_available`,
    `client_disconnected`, `lifetime_exceeded`, `key_revoked`, or
    `session_owner_lost`). `topic` is the Phoenix channel topic to join on
    `/api/v1/socket`. Never contains workspace contents, commands,
    environment values, or output.
    """,
    type: :object,
    required: [
      :id,
      :status,
      :end_reason,
      :pool,
      :project,
      :max_members,
      :wanted,
      :label,
      :topic,
      :members,
      :workspace_uploaded,
      :acquire_deadline_at,
      :ended_at,
      :inserted_at,
      :updated_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: ["waiting", "active", "released", "expired"]},
      end_reason: %Schema{
        type: :string,
        nullable: true,
        enum: [
          "no_member_available",
          "client_disconnected",
          "lifetime_exceeded",
          "key_revoked",
          "session_owner_lost"
        ]
      },
      pool: %Schema{type: :string, description: "Pool slug"},
      project: %Schema{type: :string, description: "Project slug"},
      max_members: %Schema{type: :integer, minimum: 1},
      wanted: %Schema{type: :integer, minimum: 0},
      label: %Schema{type: :string, nullable: true},
      topic: %Schema{type: :string, description: "`pool_session:<id>`"},
      members: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: [:id, :name, :ready],
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string},
            ready: %Schema{type: :boolean, description: "Workspace extracted for this lease"}
          }
        }
      },
      workspace_uploaded: %Schema{type: :boolean},
      acquire_deadline_at: %Schema{type: :string, format: :"date-time"},
      ended_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
