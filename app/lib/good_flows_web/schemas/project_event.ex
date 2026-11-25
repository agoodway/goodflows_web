defmodule GoodFlowsWeb.Schemas.ProjectEvent do
  @moduledoc "OpenAPI schema for one project event."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProjectEvent",
    description: """
    One event of the project feed. `data` holds only the type's own fields:

    - `cr_state_changed`: `from`, `to`
    - `cr_retargeted`: `from`, `to` (the old and new target branch)
    - `cr_parent_changed`: `from`, `to` (the old and new parent number, null for none)
    - `verdict_changed`: `from` (null for the first verdict), `to`, `head`, `policy_version`.
      Written whenever anything the verdict shows changes (state, head, policy version,
      reasons, scenarios, coverage, counted runs or review counts), so `from` may equal `to`
    - `scenario_set_uploaded`: `source`, `digest`, `version`
    - `scenario_set_approved`: `source`, `digest` (`source` `diff` when `diff_set_weakened`
      answers accept a diff digest)
    - `scenario_set_rejected`: `source`, `digest`, `note`
    - `answer_recorded`: `item_id`, `kind`, `head`, `answer`, `option`, `note`
    - `task_created`: `task_id`, `item_id`, `head`, `note`
    - `task_completed`: `task_id`, `item_id`
    - `policy_version_created`: `version`, `note` (`number` is null)
    - `lease_acquired`, `lease_renewed`, `lease_expired`: `lease_id`, `target_branch`,
      `expires_at` (the lease's expiry after the change; `actor` is null for expiry)
    - `lease_released`: `lease_id`, `target_branch`, `expires_at`, `release_reason`
      (`released`, `merged` or `closed`)
    - `defect_recorded`: `defect_id`, `commit`, `attribution`, `severity`, `ticket`
      (`number` is the attributed change request, or null)
    - `workflow_run_stored`: `run_id`, `workflow`, `outcome`, `commit` (one per `draft` or
      `open` change request whose head is the run's commit)
    - `verify_run_stored`: `run_id`, `commit`, `source`, `digest` (one per `draft` or `open`
      change request with a set version on the run's digest, when the run becomes `final`)

    `actor` has `key_id` null for an event caused by a signed-in member in the dashboard.
    Public keys see every `note`, the `ticket` of `defect_recorded` and `actor` as null.
    Later phases may add types.
    """,
    type: :object,
    required: [:id, :type, :number, :data, :actor, :inserted_at],
    properties: %{
      id: %Schema{type: :integer, description: "The event's cursor"},
      type: %Schema{
        type: :string,
        enum: ~w(cr_state_changed cr_retargeted cr_parent_changed verdict_changed
          scenario_set_uploaded scenario_set_approved scenario_set_rejected answer_recorded
          task_created task_completed policy_version_created lease_acquired lease_renewed
          lease_expired lease_released defect_recorded workflow_run_stored verify_run_stored)
      },
      number: %Schema{type: :integer, nullable: true, description: "Change request number"},
      data: %Schema{type: :object},
      actor: %Schema{
        type: :object,
        nullable: true,
        description: "Null for server-made events and for public keys",
        properties: %{
          user_id: %Schema{type: :string, nullable: true},
          key_id: %Schema{type: :string, nullable: true}
        }
      },
      inserted_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
