defmodule GoodFlowsWeb.Schemas.GitFactsResponse do
  @moduledoc """
  OpenAPI schema for a Git facts read: the stored document plus `totals`,
  the uploader's `user_id` and `inserted_at`. Public keys see every
  `changed_files` and `diff.files` as null.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.GitFactsDocument
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "GitFactsResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:format, :head, :target, :commits, :diff, :totals, :user_id, :inserted_at],
        properties:
          Map.merge(GitFactsDocument.schema().properties, %{
            totals: %Schema{
              type: :object,
              required: [:files, :additions, :deletions],
              properties: %{
                files: %Schema{type: :integer},
                additions: %Schema{type: :integer},
                deletions: %Schema{type: :integer}
              }
            },
            user_id: %Schema{type: :string, format: :uuid, nullable: true},
            inserted_at: %Schema{type: :string, format: :"date-time"}
          })
      }
    }
  })
end
