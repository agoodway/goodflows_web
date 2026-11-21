defmodule GoodFlowsWeb.Schemas.CodedConflictResponse do
  @moduledoc """
  OpenAPI schema for a `409` of the merge lease, parent and retarget
  routes, with an `error` value.
  """
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CodedConflictResponse",
    description: """
    `error` says why:

    - `not_open`: the change request is not `open` (acquire)
    - `stale_head`: `head` is not the last reported head, which is in `head` (acquire)
    - `not_mergeable`: the verdict is not `mergeable`; its state is in `state` (acquire)
    - `slot_taken`: another lease holds the slot; `holder` names its change request and
      expiry, never its lease ID; it is absent when the slot kept changing during
      the acquire and its final slot has no live lease (acquire)
    - `lease_not_active`: the lease ID is unknown, released or expired (heartbeat, release)
    - `not_editable`: the change request is not `draft` or `open` (parent, retarget), or its
      parent link kept changing during the retarget (retarget)
    - `parent_not_merged`: the parent is not merged yet (retarget)
    - `lease_held`: the change request holds an active merge lease (retarget)
    """,
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail, :error],
        properties: %{
          detail: %Schema{type: :string},
          error: %Schema{
            type: :string,
            enum: ~w(not_open stale_head not_mergeable slot_taken lease_not_active
              not_editable parent_not_merged lease_held)
          },
          head: %Schema{type: :string, nullable: true},
          state: %Schema{type: :string, enum: ~w(pending blocked needs_review)},
          holder: %Schema{
            type: :object,
            required: [:change_request, :expires_at],
            properties: %{
              change_request: %Schema{type: :integer, minimum: 1},
              expires_at: %Schema{type: :string, format: :"date-time"}
            }
          }
        }
      }
    },
    example: %{
      "errors" => %{
        "detail" => "Another lease holds the merge slot",
        "error" => "slot_taken",
        "holder" => %{"change_request" => 42, "expires_at" => "2026-11-21T12:10:00Z"}
      }
    }
  })
end
