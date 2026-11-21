defmodule GoodFlowsWeb.Schemas.ReviewItem do
  @moduledoc "OpenAPI schema for one review packet item."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewItem",
    description: """
    One reason that needs a person. `id` is `<rule>:<sha256 of the subject's canonical
    JSON>` and identifies the item only together with the head it was read at.
    `data` per kind:

    - `scenario_set_approval`: `digest`, `version`, `approved_digest` (last approved, or
      null), `changes` (weakening first)
    - `diff_only_set`: `digest`, `revision`, `scenarios` (`id`, `priority`, `result`, `run_id`)
    - `diff_set_weakened`: `id`, `change` (`removed` or `demoted`), `from_priority`,
      `to_priority`, `version` and `digest` (the current diff version), `baseline`
      (`version`, `digest`), `edited_musts` (IDs that are `must` in both versions with a
      different section digest). Answers are `approve` or `reject` under
      `scenarios.approver`; approving every one accepts the diff digest
    - `failed_scenario`: `id`, `priority`, `digest`, `run_id`, `commit`, `failed_step`,
      `reason`, `artifacts`
    - `not_run`: `id`, `priority`, `digest`, `run_id`, `reason`
    - `spec_gap`: `capability`, `requirement`, `scenario`, `digest`, `version`,
      `covering_claims` (`fact`, `proof`, `evidence`)
    - `one_way_door`: `door_reason`, `reach`, `decisions` (`id`, `path`, `hunk`, `note`)
    - `unproven_claim`: `min_proof_level`, `claims` (`fact`, `location`, `proof`,
      `evidence`, `covers`)
    - `open_item`: `risk`, `location`, `affected`
    - `question`: `id`, `text`, `options`, `recommendation`
    - `sensitive_path`: `glob`, `files` (`path`, `old_path`, `additions`, `deletions`),
      `decisions`
    - `size`: `limit`, `changed_files`, `changed_lines`, `max_changed_files`,
      `max_changed_lines`
    - `unmapped_area`: `paths`, `feature_index_version`
    - `undriven_feature`: `id`, `title`, `paths`

    Each artifact has `id`, `content_type`, `size`, `url` and `expires_at` (a GET URL
    presigned on this read, valid 15 minutes; null without object storage) and
    `expired` (true, with no URL, once retention deleted the object).
    """,
    type: :object,
    required: [:id, :kind, :rule, :subject, :message, :data, :answers, :answer],
    properties: %{
      id: %Schema{type: :string},
      kind: %Schema{
        type: :string,
        enum: ~w(scenario_set_approval diff_only_set diff_set_weakened failed_scenario not_run
          spec_gap one_way_door unproven_claim open_item question sensitive_path size
          unmapped_area undriven_feature)
      },
      rule: %Schema{type: :string},
      subject: %Schema{type: :array, items: %Schema{type: :string}},
      message: %Schema{type: :string},
      data: %Schema{type: :object},
      answers: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: ~w(approve reject request_change choose)}
      },
      answer: %Schema{
        type: :object,
        nullable: true,
        description: "The current answer at the head (a `ReviewAnswer`), or null"
      }
    }
  })
end
