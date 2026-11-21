defmodule GoodFlowsWeb.Schemas.ChangeRequestMerge do
  @moduledoc "OpenAPI schema for a recorded merge and the verdict at its head."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.VerdictReason
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequestMerge",
    description: "Written once when the merge is reported; never changes afterwards.",
    type: :object,
    nullable: true,
    required: [
      :merged_commit,
      :target_branch,
      :merged_at,
      :head,
      :verdict_state,
      :policy_version,
      :reasons,
      :merged_without_mergeable_verdict,
      :merged_without_lease
    ],
    properties: %{
      merged_commit: %Schema{type: :string},
      target_branch: %Schema{type: :string},
      merged_at: %Schema{type: :string, format: :"date-time"},
      head: %Schema{type: :string, nullable: true},
      verdict_state: %Schema{type: :string, enum: ~w(pending blocked needs_review mergeable)},
      policy_version: %Schema{type: :integer, minimum: 0},
      reasons: %Schema{type: :array, items: VerdictReason},
      merged_without_mergeable_verdict: %Schema{type: :boolean},
      merged_without_lease: %Schema{
        type: :boolean,
        description:
          "True unless the report named the change request's active, unexpired merge lease"
      }
    }
  })
end
