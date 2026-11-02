defmodule GoodFlowsWeb.Schemas.Pool do
  @moduledoc "OpenAPI schema for a Sprite pool."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @count %Schema{type: :integer, minimum: 0}

  OpenApiSpex.schema(%{
    title: "Pool",
    description: """
    A project's pool of pre-built Sprite VMs. `status` is `credential_missing`
    while the account has no Sprites credential (no members are provisioned
    then). `members` counts members by state. Provisioning failures back off:
    `provision_failures` is the current streak and `next_provision_at` the
    next attempt (or null). `idle_ttl_ms` is the opt-in idle shrink (null:
    off). Checkpoint ids, worker owner ids, and the Sprites token are never
    returned.
    """,
    type: :object,
    required: [
      :id,
      :slug,
      :project,
      :setup,
      :setup_version,
      :min_ready,
      :max_members,
      :idle_ttl_ms,
      :status,
      :members,
      :provision_failures,
      :next_provision_at,
      :last_provision_error,
      :inserted_at,
      :updated_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      slug: %Schema{type: :string},
      project: %Schema{type: :string, description: "The owning project's slug"},
      setup: %Schema{type: :array, items: %Schema{type: :string}},
      setup_version: %Schema{type: :integer, minimum: 1},
      min_ready: %Schema{type: :integer, minimum: 0},
      max_members: %Schema{type: :integer, minimum: 1},
      idle_ttl_ms: %Schema{type: :integer, minimum: 60_000, nullable: true},
      status: %Schema{type: :string, enum: ["active", "credential_missing"]},
      members: %Schema{
        type: :object,
        description: "Member counts by state",
        properties: %{
          provisioning: @count,
          idle: @count,
          leased: @count,
          resetting: @count,
          broken: @count,
          destroying: @count,
          abandoned: @count
        }
      },
      provision_failures: %Schema{type: :integer, minimum: 0},
      next_provision_at: %Schema{type: :string, format: :"date-time", nullable: true},
      last_provision_error: %Schema{type: :string, nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    example: %{
      "id" => "0b8e2f1c-3d4a-4b5c-8d9e-0f1a2b3c4d5e",
      "slug" => "rust-ci",
      "project" => "app",
      "setup" => ["curl -sSf https://sh.rustup.rs | sh -s -- -y"],
      "setup_version" => 1,
      "min_ready" => 1,
      "max_members" => 4,
      "idle_ttl_ms" => nil,
      "status" => "active",
      "members" => %{
        "provisioning" => 0,
        "idle" => 1,
        "leased" => 0,
        "resetting" => 0,
        "broken" => 0,
        "destroying" => 0,
        "abandoned" => 0
      },
      "provision_failures" => 0,
      "next_provision_at" => nil,
      "last_provision_error" => nil,
      "inserted_at" => "2026-11-01T12:00:00.000000Z",
      "updated_at" => "2026-11-01T12:00:00.000000Z"
    }
  })
end
