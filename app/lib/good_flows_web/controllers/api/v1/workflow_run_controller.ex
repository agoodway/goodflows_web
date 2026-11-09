defmodule GoodFlowsWeb.Api.V1.WorkflowRunController do
  @moduledoc """
  Stores and reads workflow runs under
  `/api/v1/projects/:project/workflow-runs`.

  `POST` is on the project write pipeline (`:api`, `:api_authenticated`,
  `:api_write`, `:load_project`) so a public key is `403` and a missing
  key is `401` before `GoodFlowsWeb.Plugs.WorkflowRunBody` reads the body.
  `GET` is on the project read pipeline (`:api`, `:api_authenticated`,
  `:load_project`): any valid key of the account can list and show.
  `LoadProject` resolves the slug before the body plug, so an invalid slug
  is `422` and an unknown slug is `404` without reading the body.

  The create action passes only the decoded body from `conn.private` to
  `GoodFlows.WorkflowRuns.ingest/4`, never `conn.params`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.WorkflowRuns
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.WorkflowRunBody
  alias GoodFlowsWeb.Schemas.WorkflowRunParts

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    ValidationErrorResponse,
    WorkflowRunAcknowledgement,
    WorkflowRunListResponse,
    WorkflowRunRequest,
    WorkflowRunResponse
  }

  alias OpenApiSpex.Schema

  plug WorkflowRunBody when action in [:create]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Workflow runs"])

  @document_props WorkflowRunParts.document().properties

  @list_parameters ApiParams.project() ++
                     [
                       limit: [
                         in: :query,
                         schema: %Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
                         description: "Page size from 1 to 200. The default is 50.",
                         required: false
                       ],
                       cursor: [
                         in: :query,
                         type: :string,
                         description:
                           "The `next_cursor` of the previous page. Any other value is `422`.",
                         required: false
                       ],
                       workflow: [
                         in: :query,
                         schema: @document_props["workflow"],
                         description:
                           "Exact workflow name. A value that breaks the name rule is `422`.",
                         required: false
                       ],
                       environment: [
                         in: :query,
                         schema: @document_props["environment"],
                         description:
                           "Exact environment name. A value that breaks the name rule is `422`.",
                         required: false
                       ],
                       outcome: [
                         in: :query,
                         schema: @document_props["outcome"],
                         description: "Exact outcome: `passed`, `failed` or `cancelled`.",
                         required: false
                       ],
                       commit: [
                         in: :query,
                         schema: @document_props["source"].properties["commit"],
                         description:
                           "Exact `source.commit` (40 or 64 lowercase hex characters). " <>
                             "Any other value is `422`.",
                         required: false
                       ],
                       graph_sha256: [
                         in: :query,
                         schema: @document_props["graph_sha256"],
                         description:
                           "Exact graph hash (64 lowercase hex characters). Any other value is `422`.",
                         required: false
                       ]
                     ]

  operation(:create,
    summary: "Store a workflow run",
    description: """
    Stores one `schema_version` 1 run-history document for the project in the
    URL. The body has no `project` or `account_id`. The first upload is
    `201`. An exact retry (equal JSON ignoring object key order) is `200`
    with the same `id` and `duplicate: true`. Any other body under that
    `run_id` is `409` and does not reveal the stored id or document.
    Acknowledgements return only `id`, `run_id` and `duplicate`.

    On `503` the run may or may not be stored: retry the same body. There
    is no admission cap on this route.
    """,
    parameters: ApiParams.project(),
    request_body:
      {"Run-history document", "application/json", WorkflowRunRequest, required: true},
    responses: [
      created: {"Stored", "application/json", WorkflowRunAcknowledgement},
      ok: {"Exact retry of a stored run", "application/json", WorkflowRunAcknowledgement},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      request_timeout:
        {"The body was not received before the read deadline", "application/json", ErrorResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      conflict:
        {"A different run is stored under this run id", "application/json", ConflictResponse},
      request_entity_too_large: {"Body exceeds 4 MiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid document, nesting deeper than 8 levels (on `body`) or invalid project slug",
         "application/json", ValidationErrorResponse},
      service_unavailable:
        {"Storage unavailable; retry the same body after `Retry-After`", "application/json",
         ErrorResponse}
    ]
  )

  @doc """
  Validates and stores the normalized document from `WorkflowRunBody`.
  """
  def create(conn, _params) do
    %{current_account: account, project: project, current_api_key: api_key} = conn.assigns
    document = conn.private.workflow_run_document

    case WorkflowRuns.ingest(account, project, api_key, document) do
      {:ok, ack} ->
        conn
        |> put_status(if(ack.duplicate, do: :ok, else: :created))
        |> render(:show, ack: ack)

      {:error, _reason} = error ->
        error
    end
  end

  operation(:index,
    summary: "List a project's workflow runs",
    description: """
    Newest `started_at` first, with ties broken by `run_id` descending.
    Pages use keyset pagination on that order. Pass `next_cursor` as
    `cursor`. A run stored after a page was read does not shift the next
    page. Unknown query parameters are ignored. Summaries do not include
    `results`. Any valid key of the account can list.
    """,
    parameters: @list_parameters,
    responses: [
      ok: {"One page of run summaries", "application/json", WorkflowRunListResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid filter, limit, cursor or project slug", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Lists one page of the project's workflow runs."
  def index(conn, params) do
    filters =
      Map.take(params, ~w(limit cursor workflow environment outcome commit graph_sha256))

    %{current_account: account, project: project} = conn.assigns

    with {:ok, page} <- WorkflowRuns.list_runs(account, project, filters) do
      render(conn, :index, runs: page.runs, next_cursor: page.next_cursor)
    end
  end

  operation(:show,
    summary: "Show a workflow run",
    description: """
    Returns the stored document and the test reports in this account and
    project whose `workflow_run_id` equals the run, ordered by `job` then
    `report_id`, without report contents. `run_id` must be a lowercase
    canonical UUID. Any other spelling, including uppercase, is `404` and
    is not looked up.

    A public (`pk_`) key receives each result's `command` and `error` as
    null. A private key sees them as stored. The stored row does not change.
    """,
    parameters:
      ApiParams.project() ++
        [
          run_id: [
            in: :path,
            type: :string,
            description:
              "Lowercase canonical UUID. Any other spelling, including uppercase, is `404`.",
            required: true
          ]
        ],
    responses: [
      ok: {"The stored run", "application/json", WorkflowRunResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      not_found:
        {"No such project, or no run with that lowercase id", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Shows one run. Public keys do not receive command text or errors."
  def show(conn, %{"run_id" => run_id}) do
    %{current_account: account, project: project, current_api_key: api_key} = conn.assigns

    with {:ok, result} <- WorkflowRuns.get_run(account, project, run_id) do
      render(conn, :show, Map.put(result, :redact?, not ApiKey.can_write?(api_key)))
    end
  end
end
