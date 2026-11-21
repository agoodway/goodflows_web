defmodule GoodFlowsWeb.Schemas.VerdictReason do
  @moduledoc "OpenAPI schema for one verdict reason."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerdictReason",
    description:
      "One rule that fired. `rule` plus `subject` identifies the reason. Public keys " <>
        "see `subject` and `message` as null.",
    type: :object,
    required: [:rule, :outcome, :subject, :message],
    properties: %{
      rule: %Schema{
        type: :string,
        enum: ~w(git_facts_missing claims_missing required_workflow_missing
          required_workflow_failed one_way_door proof_below_minimum open_items path_match
          max_changed_files max_changed_lines)
      },
      outcome: %Schema{type: :string, enum: ~w(pending blocked needs_review)},
      subject: %Schema{
        type: :array,
        items: %Schema{type: :string},
        nullable: true,
        description: "Sorted unless the rule defines an order (`path_match`: glob first)"
      },
      message: %Schema{type: :string, nullable: true}
    }
  })
end
