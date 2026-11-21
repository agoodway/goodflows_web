defmodule GoodFlowsWeb.Api.V1.VerifyRunController do
  @moduledoc """
  Verify runs under `/api/v1/projects/:project/verify-runs`.

  Upload and commit are on the project write pipeline (`sk_` keys), so a
  public key is `403` and the project is resolved before
  `GoodFlowsWeb.Plugs.JsonBody` reads the body (workflow-run limits, 4
  MiB). List and show are on the project read pipeline (`sk_` and `pk_`
  keys; public keys get redacted views, see
  `GoodFlowsWeb.Api.V1.VerifyRunJSON`). `ck_` keys are `403` everywhere.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.VerifyRuns
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.JsonBody

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    ValidationErrorResponse,
    VerifyRunAcknowledgement,
    VerifyRunListResponse,
    VerifyRunRequest,
    VerifyRunResponse
  }

  alias OpenApiSpex.Schema

  plug JsonBody,
       [limit: :workflow_run_max_body_bytes, default: 4_194_304] when action in [:create]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Verify runs"])

  @run_id_param [
    run_id: [
      in: :path,
      type: :string,
      description: "Lowercase canonical UUID. Any other spelling is `404`.",
      required: true
    ]
  ]

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}

  operation(:create,
    summary: "Upload a verify run",
    description: """
    Stores one `verify-run/1` document for the project. `scenario_set.digest`
    must be a stored set of the project with that `source`, and `results`
    must hold exactly its scenario IDs (`422` otherwise). The first upload
    is `201`; the same document (canonical JSON) is `200` with `duplicate`
    true; a different one under the `run_id` is `409`. A run without
    artifacts is `final` at once. A run with artifacts is `uploading`: PUT
    each artifact to its `upload_url` with exactly its `upload_headers`
    (length, content type and SHA-256 are signed in), then commit before
    `expires_at`. A retry while `uploading` returns fresh URLs. Artifacts
    over 50 MB are `413`; artifacts without a configured bucket are `503`.
    Presigned URLs are bearer credentials.
    """,
    parameters: ApiParams.project(),
    request_body: {"verify-run/1 document", "application/json", VerifyRunRequest, required: true},
    responses: [
      created: {"Stored", "application/json", VerifyRunAcknowledgement},
      ok: {"Exact retry", "application/json", VerifyRunAcknowledgement},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden: {"Public or cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      conflict:
        {"A different run is stored under this run id", "application/json", ConflictResponse},
      request_entity_too_large:
        {"Body exceeds 4 MiB, or an artifact exceeds 50 MB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid document or project slug", "application/json", ValidationErrorResponse},
      service_unavailable:
        {"Artifacts declared and no object storage configured", "application/json", ErrorResponse}
    ]
  )

  @doc "Stores a verify run."
  def create(conn, _params) do
    %{current_account: account, project: project, current_api_key: api_key} = conn.assigns

    with {:ok, ingested} <- VerifyRuns.ingest(account, project, api_key, conn.private.json_body) do
      conn
      |> put_status(if(ingested.duplicate, do: :ok, else: :created))
      |> render(:ack, ingested: ingested)
    end
  end

  operation(:commit,
    summary: "Commit an uploading verify run",
    description: """
    Checks each artifact object's length and SHA-256 and makes the run
    `final` (`200`). Missing or mismatched objects are `422` on
    `artifacts` naming the artifact IDs, and the run stays `uploading`.
    A `final` run is `200` again. A run that does not exist, has expired,
    or was uploaded by another key is `404`. An unreachable store is `503`
    with `retry-after`.
    """,
    parameters: ApiParams.project() ++ @run_id_param,
    responses: [
      ok: {"Final", "application/json", VerifyRunResponse},
      unauthorized: @unauthorized,
      forbidden: {"Public or cache keys", "application/json", ErrorResponse},
      not_found: {"No such run for this key", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Missing or mismatched artifacts, or invalid project slug", "application/json",
         ValidationErrorResponse},
      service_unavailable: {"Object store unavailable; retry", "application/json", ErrorResponse}
    ]
  )

  @doc "Commits an uploading run."
  def commit(conn, %{"run_id" => run_id}) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with {:ok, _run} <- VerifyRuns.commit(project, api_key, run_id),
         {:ok, run} <- VerifyRuns.get(project, run_id) do
      render(conn, :show, run: run, redact?: false)
    end
  end

  operation(:index,
    summary: "List a project's verify runs",
    description:
      "Newest `finished_at` first, ties by `run_id` descending, keyset-paged. Filters " <>
        "`commit`, `digest` (scenario set digest) and `status` are exact.",
    parameters:
      ApiParams.project() ++
        [
          limit: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
            required: false
          ],
          cursor: [in: :query, type: :string, description: "`next_cursor`", required: false],
          commit: [in: :query, type: :string, required: false],
          digest: [in: :query, type: :string, required: false],
          status: [
            in: :query,
            schema: %Schema{type: :string, enum: ~w(uploading final)},
            required: false
          ]
        ],
    responses: [
      ok: {"One page of runs", "application/json", VerifyRunListResponse},
      unauthorized: @unauthorized,
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid filter, limit, cursor or project slug", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Lists one page of verify runs."
  def index(conn, params) do
    with {:ok, page} <-
           VerifyRuns.list(
             conn.assigns.project,
             Map.take(params, ~w(limit cursor commit digest status))
           ) do
      render(conn, :index, runs: page.runs, next_cursor: page.next_cursor)
    end
  end

  operation(:show,
    summary: "Show a verify run",
    description: """
    The stored `document` and its artifacts with `expired`. A private key
    gets a `download_url` for each unexpired artifact of a `final` run.
    Public keys see results' `reason` and `failed_step`, features'
    `entry_point`, `source.changed_files` and `links.threads` as null.
    """,
    parameters: ApiParams.project() ++ @run_id_param,
    responses: [
      ok: {"The run", "application/json", VerifyRunResponse},
      unauthorized: @unauthorized,
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: {"No such project or run", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Shows one verify run."
  def show(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- VerifyRuns.get(conn.assigns.project, run_id) do
      render(conn, :show, run: run, redact?: not ApiKey.can_write?(conn.assigns.current_api_key))
    end
  end
end
