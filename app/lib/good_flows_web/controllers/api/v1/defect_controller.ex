defmodule GoodFlowsWeb.Api.V1.DefectController do
  @moduledoc """
  Defects under `/api/v1/projects/:project/defects`. Recording is on the
  project write pipeline (`sk_` keys only); listing is on the project read
  pipeline (`sk_` and `pk_` keys; public keys see `ticket` null). `ck_`
  keys are `403` on both. See `GoodFlows.Calibration`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Calibration
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.JsonBody

  alias GoodFlowsWeb.Schemas.{
    DefectListResponse,
    DefectRequest,
    DefectResponse,
    ErrorResponse,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema

  plug JsonBody,
       [limit: :change_request_max_body_bytes, default: 65_536] when action in [:create]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Review calibration"])

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_found {"No such project in this account", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}

  operation(:create,
    summary: "Record a defect",
    description: """
    Records a defect found after a merge, naming exactly one of
    `change_request` (a number of the project) or `commit`. A commit is
    attributed to the earliest merged change request whose `merged_commit`
    is that SHA or whose merged head's `git-facts` commits list it, so the
    commit a squash or rebase merge created on the target also matches,
    else stored with `change_request: null`
    and `attribution: "unattributed"`; attribution never changes later.
    Recording a defect changes no policy and recomputes no verdict.
    Strict JSON, 64 KiB.
    """,
    parameters: ApiParams.project(),
    request_body: {"Defect", "application/json", DefectRequest, required: true},
    responses: [
      created: {"Recorded", "application/json", DefectResponse},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden: {"Public or cache keys", "application/json", ErrorResponse},
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid body (on `body`, `change_request`, `commit`, `severity` or `ticket`) or " <>
           "project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Records a defect."
  def create(conn, _params) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with {:ok, defect} <- Calibration.record_defect(project, api_key, conn.private.json_body) do
      conn |> put_status(:created) |> render(:show, defect: defect, redact?: false)
    end
  end

  operation(:index,
    summary: "List defects",
    description: "Newest first, keyset-paged. Public keys see `ticket` as null.",
    parameters:
      ApiParams.project() ++
        [
          limit: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
            required: false
          ],
          cursor: [in: :query, type: :string, description: "`next_cursor`", required: false]
        ],
    responses: [
      ok: {"One page of defects", "application/json", DefectListResponse},
      unauthorized: @unauthorized,
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid limit, cursor or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Lists one page of defects."
  def index(conn, params) do
    with {:ok, page} <-
           Calibration.list_defects(conn.assigns.project, Map.take(params, ~w(limit cursor))) do
      render(conn, :index,
        defects: page.defects,
        next_cursor: page.next_cursor,
        redact?: not ApiKey.can_write?(conn.assigns.current_api_key)
      )
    end
  end
end
