defmodule GoodFlowsWeb.Schemas.GitFactsDocument do
  @moduledoc "OpenAPI schema for a `git-facts/1` report."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @sha %Schema{type: :string, pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$"}

  @file_entry %Schema{
    type: :object,
    additionalProperties: false,
    required: [:path, :status, :additions, :deletions],
    properties: %{
      path: %Schema{type: :string, minLength: 1, maxLength: 4096},
      status: %Schema{
        type: :string,
        enum: ~w(added modified deleted renamed copied type_changed)
      },
      additions: %Schema{type: :integer, minimum: 0},
      deletions: %Schema{type: :integer, minimum: 0},
      old_path: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 4096,
        description: "Required for `renamed` and `copied`, absent otherwise"
      }
    }
  }

  OpenApiSpex.schema(%{
    title: "GitFactsDocument",
    type: :object,
    additionalProperties: false,
    required: [:format, :head, :target, :commits, :diff],
    properties: %{
      format: %Schema{type: :string, enum: ["git-facts/1"]},
      head: @sha,
      target: %Schema{
        type: :object,
        additionalProperties: false,
        required: [:branch, :merge_base],
        properties: %{
          branch: %Schema{type: :string, description: "The change request's `target_branch`"},
          merge_base: @sha
        }
      },
      commits: %Schema{
        type: :array,
        maxItems: 1000,
        description: "Merge base to head, oldest first; the last `sha` is `head`",
        items: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:sha, :parents, :changed_files],
          properties: %{
            sha: @sha,
            parents: %Schema{type: :array, minItems: 1, items: @sha},
            changed_files: %Schema{
              type: :array,
              maxItems: 10_000,
              items: @file_entry,
              nullable: true
            }
          }
        }
      },
      diff: %Schema{
        type: :object,
        additionalProperties: false,
        required: [:files],
        properties: %{
          files: %Schema{type: :array, maxItems: 10_000, items: @file_entry, nullable: true}
        }
      }
    }
  })
end
