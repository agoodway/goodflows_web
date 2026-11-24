defmodule GoodFlowsWeb.Schemas.GitFactsResponse do
  @moduledoc """
  OpenAPI schema for a Git facts read: the stored document plus `totals`,
  `previous_head` and `head_kind` (both null for a report stored before
  they existed), the uploader's `user_id` and `inserted_at`. Public keys see every
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
        required: [
          :format,
          :head,
          :target,
          :commits,
          :diff,
          :totals,
          :previous_head,
          :head_kind,
          :user_id,
          :inserted_at
        ],
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
            previous_head: %Schema{
              type: :string,
              nullable: true,
              description: "The change request's head before this report"
            },
            head_kind: %Schema{
              type: :string,
              nullable: true,
              enum: ~w(first fast_forward target_merged rebase rewrite retarget),
              description: "How the head moved from previous_head"
            },
            user_id: %Schema{type: :string, format: :uuid, nullable: true},
            inserted_at: %Schema{type: :string, format: :"date-time"}
          })
      }
    }
  })
end
