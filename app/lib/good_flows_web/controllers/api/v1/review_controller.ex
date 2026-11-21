defmodule GoodFlowsWeb.Api.V1.ReviewController do
  @moduledoc """
  The review packet, answers and tasks of a change request under
  `/api/v1/projects/:project/change-requests/:number`.

  Every route is on the project write pipeline: `sk_` keys only (`pk_`
  and `ck_` keys are `403`). `GoodFlowsWeb.Plugs.LoadChangeRequest`
  resolves `:number` first. An answer to a change request that is not
  `draft` or `open` is `409` before its body is read
  (`GoodFlowsWeb.Plugs.JsonBody`), so a closed or merged change request is
  always `409`; see `GoodFlows.Review.answer/5` for the order of the other
  checks.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.ChangeRequests
  alias GoodFlows.Review
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest}

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    ReviewAnswerRequest,
    ReviewAnswerResponse,
    ReviewPacketResponse,
    ReviewTaskListResponse,
    ReviewTaskResponse,
    StaleHeadResponse,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema

  plug LoadChangeRequest
  plug :require_active when action in [:answer]

  plug JsonBody,
       [limit: :change_request_max_body_bytes, default: 65_536] when action in [:answer]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Review"])

  @number_param [
    number: [in: :path, type: :integer, description: "Change request number", required: true]
  ]

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @forbidden {"Public or cache keys", "application/json", ErrorResponse}
  @not_found {"No such project or change request", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  @invalid_path {"Invalid project slug or number", "application/json", ValidationErrorResponse}

  operation(:show,
    summary: "Read the review packet",
    description: """
    The items at the change request's current head that need a person: one
    per `needs_review` reason of the stored verdict (`open_items` split into
    `question` and `open_item` items), plus a `scenario_set_approval` item
    while the current intent digest is unapproved. `pending` and `blocked`
    reasons are listed as context and are not answerable. Each item has
    its `data`, the `answers` it allows and its current `answer` at the
    head. Artifact URLs are presigned on each read for 15 minutes. Hunks
    come only from the claims' `decisions`.
    """,
    parameters: ApiParams.project() ++ @number_param,
    responses: [
      ok: {"The packet", "application/json", ReviewPacketResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Reads the review packet."
  def show(conn, _params) do
    render(conn, :packet, packet: Review.packet(conn.assigns.change_request))
  end

  operation(:answer,
    summary: "Answer a review packet item",
    description: """
    Stores an answer bound to `head` (`201`): `approve`, `reject`,
    `request_change` or `choose` (with an `option` of the question),
    as the item's `answers` allow. A later answer to the same item at the
    same head replaces the earlier one, whose `open` task becomes `stale`.
    `request_change` and `reject` create a task. `approve` and `reject` on
    a `scenario_set_approval` item record the same decision on the set
    digest as the approval and rejection calls and follow
    `scenarios.approver`; any private key answers other items. A new head
    starts a full review: answers count only at the head they were given
    at. Checked in order: the change request is `draft` or `open` (`409`),
    the body (`422`), `head` is current (`409` with the current `head`),
    the item exists at the head (`404`), the answer suits it (`422`), the
    approver (`403`). Strict JSON, 64 KiB.
    """,
    parameters:
      ApiParams.project() ++
        @number_param ++
        [item_id: [in: :path, type: :string, description: "Item `id`", required: true]],
    request_body: {"Answer", "application/json", ReviewAnswerRequest, required: true},
    responses: [
      created: {"Stored", "application/json", ReviewAnswerResponse},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden:
        {"Public or cache keys, or refused by `scenarios.approver`", "application/json",
         ErrorResponse},
      not_found:
        {"No such project or change request, or no such item at the current head",
         "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      conflict:
        {"Not `draft` or `open`, or not the current head", "application/json", StaleHeadResponse},
      request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid body, answer or option, or invalid project slug or number", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Stores an answer."
  def answer(conn, %{"item_id" => item_id}) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, answer} <-
           Review.answer(
             change_request,
             conn.assigns.current_account_user,
             api_key,
             item_id,
             conn.private.json_body
           ) do
      conn |> put_status(:created) |> render(:answer, answer: answer)
    end
  end

  operation(:tasks,
    summary: "List review tasks",
    description:
      "Tasks oldest first. `state` filters (`open`, `stale` or `done`); without it, " <>
        "`open` and `stale` tasks.",
    parameters:
      ApiParams.project() ++
        @number_param ++
        [
          state: [
            in: :query,
            schema: %Schema{type: :string, enum: ~w(open stale done)},
            required: false
          ]
        ],
    responses: [
      ok: {"The tasks", "application/json", ReviewTaskListResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid state, project slug or number", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Lists tasks."
  def tasks(conn, params) do
    change_request = conn.assigns.change_request

    with {:ok, tasks} <- Review.list_tasks(change_request, Map.take(params, ["state"])) do
      render(conn, :tasks, tasks: tasks, number: change_request.number)
    end
  end

  operation(:done,
    summary: "Mark a review task done",
    description:
      "Sets an `open` or `stale` task to `done` with the membership and time. A `done` " <>
        "task is `200` unchanged. Takes no body.",
    parameters:
      ApiParams.project() ++
        @number_param ++
        [task_id: [in: :path, type: :string, description: "Task `id`", required: true]],
    responses: [
      ok: {"The task", "application/json", ReviewTaskResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such project, change request or task", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Marks a task done."
  def done(conn, %{"task_id" => task_id}) do
    change_request = conn.assigns.change_request

    with {:ok, task} <-
           Review.complete_task(change_request, conn.assigns.current_account_user, task_id) do
      render(conn, :task, task: task, number: change_request.number)
    end
  end

  defp require_active(conn, _opts) do
    case ChangeRequests.require_active(conn.assigns.change_request) do
      :ok -> conn
      {:error, reason} -> conn |> GoodFlowsWeb.FallbackController.call({:error, reason}) |> halt()
    end
  end
end
