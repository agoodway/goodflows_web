defmodule GoodFlowsWeb.Api.V1.MergeLeaseController do
  @moduledoc """
  Merge slot leases under `/api/v1/projects/:project`: acquire for a change
  request (`POST …/change-requests/:number/merge-lease`), heartbeat
  (`POST …/merge-leases/:lease_id/heartbeat`) and release
  (`DELETE …/merge-leases/:lease_id`).

  Every route is on the project write pipeline: `sk_` keys of the account
  only (`pk_` and `ck_` keys are `403`). Any private key of the account
  that names a lease ID may heartbeat or release it. See
  `GoodFlows.MergeLeases` for the rules.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.MergeLeases
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest}

  alias GoodFlowsWeb.Schemas.{
    CodedConflictResponse,
    ErrorResponse,
    MergeLeaseRequest,
    MergeLeaseResponse,
    ValidationErrorResponse
  }

  plug LoadChangeRequest when action in [:acquire]

  plug JsonBody,
       [limit: :change_request_max_body_bytes, default: 65_536] when action in [:acquire]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Merge leases"])

  @number_param [
    number: [in: :path, type: :integer, description: "Change request number", required: true]
  ]

  @lease_param [
    lease_id: [
      in: :path,
      type: :string,
      description: "Lease ID. One that names no active lease of the project is `409`.",
      required: true
    ]
  ]

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @forbidden {"Public or cache keys", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  @not_active {"`lease_not_active`: unknown, released or expired lease", "application/json",
               CodedConflictResponse}

  operation(:acquire,
    summary: "Acquire the merge slot",
    description: """
    Takes the merge slot of the project and the change request's
    `target_branch` for `merge.lease_ttl` (default 10 minutes). The change
    request must be `open` (else `not_open`), `head` its last reported head
    (else `stale_head` with the current `head`) and its verdict `mergeable`
    (else `not_mergeable` with its `state`). A slot held by a live lease is
    `slot_taken` with the holder's change request number and expiry; there
    is no queue. When the slot keeps moving (a concurrent retarget) through
    every retry, the change request is re-read and the answer is
    `not_open`, `stale_head`, the lease this key already holds there
    (`200`), `slot_taken` with the holder of a live lease on its current
    slot, or `slot_taken` without `holder` when that slot is free. The same key asking again for the change request that
    holds the lease, at the same head, gets that lease back (`200`). A
    lease past its `expires_at` holds no slot. Holding the lease does not
    stop other clients from merging; it coordinates cooperating clients.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body: {"Head and base", "application/json", MergeLeaseRequest, required: true},
    responses: [
      created: {"Acquired", "application/json", MergeLeaseResponse},
      ok: {"The lease this key already holds", "application/json", MergeLeaseResponse},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such project or change request", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      conflict:
        {"`not_open`, `stale_head`, `not_mergeable` or `slot_taken` (with `holder` when known)",
         "application/json", CodedConflictResponse},
      request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid `head` or `base`, project slug or number", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Acquires the merge slot for a change request."
  def acquire(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, status, lease} <-
           MergeLeases.acquire(change_request, api_key, conn.private.json_body) do
      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> render(:show, lease: lease, number: change_request.number)
    end
  end

  operation(:heartbeat,
    summary: "Extend a merge lease",
    description:
      "Sets `expires_at` of an active, unexpired lease to now plus its TTL. There is no " <>
        "overall cap on how long heartbeats keep a lease.",
    parameters: ApiParams.project() ++ @lease_param,
    responses: [
      ok: {"Extended", "application/json", MergeLeaseResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such project", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      conflict: @not_active,
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Extends a merge lease."
  def heartbeat(conn, %{"lease_id" => lease_id}) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with {:ok, lease} <- MergeLeases.heartbeat(project, api_key, lease_id) do
      render(conn, :show, lease: lease, number: lease_number(lease))
    end
  end

  operation(:release,
    summary: "Release a merge lease",
    description:
      "Releases an active, unexpired lease (`release_reason: \"released\"`) and frees the " <>
        "slot; the change request keeps its state.",
    parameters: ApiParams.project() ++ @lease_param,
    responses: [
      no_content: "Released",
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such project", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      conflict: @not_active,
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Releases a merge lease."
  def release(conn, %{"lease_id" => lease_id}) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with :ok <- MergeLeases.release(project, api_key, lease_id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp lease_number(lease), do: MergeLeases.number(lease)
end
