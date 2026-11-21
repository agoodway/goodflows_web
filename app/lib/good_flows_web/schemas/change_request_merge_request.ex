defmodule GoodFlowsWeb.Schemas.ChangeRequestMergeRequest do
  @moduledoc "OpenAPI schema for a merge report."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequestMergeRequest",
    type: :object,
    additionalProperties: false,
    required: [:merged_commit, :target_branch],
    properties: %{
      merged_commit: %Schema{type: :string, pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$"},
      target_branch: %Schema{type: :string, minLength: 1, maxLength: 256},
      lease_id: %Schema{
        type: :string,
        description:
          "The merge lease the merge was made under. One that is not the change " <>
            "request's active, unexpired lease is recorded as a merge without a lease."
      }
    }
  })
end
