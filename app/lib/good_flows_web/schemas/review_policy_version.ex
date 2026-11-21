defmodule GoodFlowsWeb.Schemas.ReviewPolicyVersion do
  @moduledoc "OpenAPI schema for one review policy version."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.ReviewPolicyDocument
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewPolicyVersion",
    description: "Public keys see `note` and `written_by` as null.",
    type: :object,
    required: [
      :version,
      :previous_version,
      :policy,
      :effective,
      :note,
      :written_by,
      :inserted_at,
      :active_settings
    ],
    properties: %{
      version: %Schema{type: :integer, minimum: 0},
      previous_version: %Schema{type: :integer, minimum: 0, nullable: true},
      policy: ReviewPolicyDocument,
      effective: ReviewPolicyDocument,
      note: %Schema{type: :string, nullable: true},
      written_by: %Schema{
        type: :object,
        nullable: true,
        properties: %{user_id: %Schema{type: :string, format: :uuid, nullable: true}}
      },
      inserted_at: %Schema{type: :string, format: :"date-time", nullable: true},
      active_settings: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Dotted settings that take effect in this server version"
      }
    }
  })
end
