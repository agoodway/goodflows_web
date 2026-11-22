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
          max_changed_files max_changed_lines scenario_set_approval scenario_set_missing
          diff_only_set diff_set_weakened diff_set_revision scenario_results_missing must_failed should_failed
          should_not_run spec_gap unmapped_area undriven_feature feature_index_missing
          parent_not_merged parent_closed merge_result_ungraded merge_result_failed)
      },
      outcome: %Schema{type: :string, enum: ~w(pending blocked needs_review)},
      subject: %Schema{
        type: :array,
        items: %Schema{type: :string},
        nullable: true,
        description:
          "Sorted unless the rule defines an order (`path_match`: glob first; scenario " <>
            "rules and `merge_result_failed`: `[source, id]`; `spec_gap`: `[capability, " <>
            "requirement, scenario]`; `parent_not_merged` and `parent_closed`: `[parent number]`; " <>
            "`merge_result_ungraded`: `[lease base]`)"
      },
      message: %Schema{type: :string, nullable: true}
    }
  })
end
