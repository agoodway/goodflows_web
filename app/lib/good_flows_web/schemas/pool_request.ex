defmodule GoodFlowsWeb.Schemas.PoolRequest do
  @moduledoc "OpenAPI schema for creating or replacing a pool."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PoolRequest",
    description: """
    Full pool body; no other keys are accepted (`project`, `org`, and
    `setup_version` are `422`). `PUT` replaces the pool: an omitted `setup`
    becomes empty, an omitted `min_ready` becomes 1, an omitted
    `idle_ttl_ms` becomes null (idle shrink off), and the body `slug`
    must equal the URL's (no renames). `setup` items are plain shell lines
    run once per member before its golden checkpoint: no `{{…}}`
    placeholders and no host steps. Changing `setup` increments
    `setup_version`, which makes existing members stale.
    """,
    type: :object,
    required: [:slug, :max_members],
    additionalProperties: false,
    properties: %{
      slug: %Schema{type: :string, minLength: 1, maxLength: 64, pattern: "^[a-z0-9][a-z0-9_-]*$"},
      setup: %Schema{
        type: :array,
        maxItems: 500,
        items: %Schema{type: :string, minLength: 1, maxLength: 10_000}
      },
      min_ready: %Schema{
        type: :integer,
        minimum: 0,
        description: "Default 1; at most max_members"
      },
      max_members: %Schema{
        type: :integer,
        minimum: 1,
        description: "At most the server's per-pool cap (default 32)"
      },
      idle_ttl_ms: %Schema{
        type: :integer,
        minimum: 60_000,
        maximum: 2_592_000_000,
        nullable: true,
        description:
          "Opt-in idle shrink (default null: off): idle members beyond min_ready plus " <>
            "unmet session demand are destroyed once idle this long"
      }
    },
    example: %{
      "slug" => "rust-ci",
      "setup" => ["curl -sSf https://sh.rustup.rs | sh -s -- -y"],
      "max_members" => 4
    }
  })
end
