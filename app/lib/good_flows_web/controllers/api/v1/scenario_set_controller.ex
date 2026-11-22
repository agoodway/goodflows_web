defmodule GoodFlowsWeb.Api.V1.ScenarioSetController do
  @moduledoc """
  Scenario sets of a change request under
  `/api/v1/projects/:project/change-requests/:number/scenario-sets`.

  Reads are on the project read pipeline (`sk_` and `pk_` keys; public
  keys get redacted views, see `GoodFlowsWeb.Api.V1.ScenarioSetJSON`).
  Upload, approve and reject are on the project write pipeline (`sk_`
  keys). `ck_` keys are `403` everywhere. `GoodFlowsWeb.Plugs.LoadChangeRequest`
  resolves `:number` before any body is read; `:source` other than
  `intent` or `diff` is `404`, and decisions on `diff` are `404`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ScenarioSets
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest}

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    ScenarioSetCompareResponse,
    ScenarioSetDecisionRequest,
    ScenarioSetDecisionResponse,
    ScenarioSetListResponse,
    ScenarioSetUploadRequest,
    ScenarioSetVersionResponse,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema

  plug :check_source when action in [:show, :compare, :approve, :reject]
  plug LoadChangeRequest

  plug JsonBody,
       [limit: :scenario_set_max_body_bytes, default: 1_048_576] when action in [:create]

  plug JsonBody,
       [limit: :change_request_max_body_bytes, default: 65_536]
       when action in [:approve, :reject]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Scenario sets"])

  @number_param [
    number: [in: :path, type: :integer, description: "Change request number", required: true]
  ]
  @source_param [
    source: [
      in: :path,
      schema: %Schema{type: :string, enum: ~w(intent diff)},
      description: "`intent` or `diff`; anything else is `404`",
      required: true
    ]
  ]

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  @read_forbidden {"Cache keys", "application/json", ErrorResponse}
  @not_found {"No such project, change request, source or version", "application/json",
              ErrorResponse}
  @invalid_path {"Invalid project slug, number or parameter", "application/json",
                 ValidationErrorResponse}
  @json_errors [
    bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
    unsupported_media_type:
      {"Not `application/json`, or a `Content-Encoding` other than `identity`",
       "application/json", ErrorResponse}
  ]

  operation(:create,
    summary: "Upload a scenario set version",
    description: """
    Stores the next version of the change request's intent or diff set (the
    front matter's `source`) from a raw `qa-scenarios/2` Markdown file,
    byte for byte (`201`). Only the YAML front matter is read. The digest is
    the SHA-256 of `content`; a file equal to the current version is `200`
    with `duplicate` true. An intent set's `change` must equal the change
    request's linked OpenSpec change. A file carrying run results is `422`:
    results belong in a verify run. Only `draft` and `open` change requests
    accept uploads (`409`). Strict JSON, 1 MiB.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body: {"Scenario set", "application/json", ScenarioSetUploadRequest, required: true},
    responses:
      [
        created: {"Stored", "application/json", ScenarioSetVersionResponse},
        ok: {"Equal to the current version", "application/json", ScenarioSetVersionResponse},
        unauthorized: @unauthorized,
        forbidden: {"Public or cache keys", "application/json", ErrorResponse},
        not_found: @not_found,
        not_acceptable: @not_acceptable,
        conflict:
          {"The change request is not `draft` or `open`", "application/json", ConflictResponse},
        request_entity_too_large: {"Body exceeds 1 MiB", "application/json", ErrorResponse},
        unprocessable_entity:
          {"Invalid body, front matter, project slug or number", "application/json",
           ValidationErrorResponse}
      ] ++ @json_errors
  )

  @doc "Uploads a scenario set version."
  def create(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, status, version} <-
           ScenarioSets.upload(change_request, api_key, conn.private.json_body) do
      approved_digests = ScenarioSets.approved_digests(change_request)

      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> render(:show,
        version: version,
        approved: ScenarioSets.approved?(version, approved_digests),
        accepted: ScenarioSets.accepted?(version, approved_digests),
        duplicate: status == :duplicate,
        redact?: false
      )
    end
  end

  operation(:index,
    summary: "List scenario sets",
    description:
      "For `intent` and `diff`: the current version and every version, newest first, " <>
        "with `approved` and `accepted`.",
    parameters: ApiParams.project() ++ @number_param,
    responses: [
      ok: {"The sets", "application/json", ScenarioSetListResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Lists the intent and diff sets."
  def index(conn, _params) do
    render(conn, :index,
      sets: ScenarioSets.list(conn.assigns.change_request),
      redact?: redact?(conn)
    )
  end

  operation(:show,
    summary: "Show a scenario set version",
    description:
      "The version's `content`, parsed `front_matter`, `sections`, `digest` and the " <>
        "decisions on its digest, oldest first.",
    parameters:
      ApiParams.project() ++
        @number_param ++
        @source_param ++
        [version: [in: :path, type: :integer, description: "Version number", required: true]],
    responses: [
      ok: {"The version", "application/json", ScenarioSetVersionResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Shows one version."
  def show(conn, %{"source" => source, "version" => version}) do
    change_request = conn.assigns.change_request

    with {:ok, number} <- parse_version(version),
         {:ok, found} <- ScenarioSets.get_version(change_request, source, number) do
      approved_digests = ScenarioSets.approved_digests(change_request)

      render(conn, :show,
        version: found,
        approved: ScenarioSets.approved?(found, approved_digests),
        accepted: ScenarioSets.accepted?(found, approved_digests),
        decisions: ScenarioSets.decisions(change_request, found.digest),
        redact?: redact?(conn)
      )
    end
  end

  defp parse_version(value) do
    case LoadChangeRequest.parse(value) do
      {:ok, number} -> {:ok, number}
      :invalid -> {:error, :not_found}
    end
  end

  @decision_responses [
    created: {"Recorded", "application/json", ScenarioSetDecisionResponse},
    ok:
      {"Equal (`decision` and `note`) to the digest's latest decision, made by the same membership",
       "application/json", ScenarioSetDecisionResponse},
    unauthorized: @unauthorized,
    forbidden:
      {"Public or cache keys, or refused by `scenarios.approver`", "application/json",
       ErrorResponse},
    not_found:
      {"No such project or change request, or a `diff` set", "application/json", ErrorResponse},
    not_acceptable: @not_acceptable,
    conflict:
      {"Not the current intent digest, or the change request is not `draft` or `open`",
       "application/json", ConflictResponse},
    request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
    unprocessable_entity: {"Invalid body", "application/json", ValidationErrorResponse}
  ]

  operation(:approve,
    summary: "Approve the current intent digest",
    description: """
    Records an `approve` decision on `digest`, which must be the current
    intent version's digest (`409` otherwise). The project's
    `scenarios.approver` decides who may (`any`, `other_member` than the
    opener, or `admin`). The approval binds to the digest, not the head.
    Only `intent` takes decisions here; `diff` is `404`, and diff digests
    take decisions only through `diff_set_weakened` review answers.
    """,
    parameters: ApiParams.project() ++ @number_param ++ @source_param,
    request_body: {"Approval", "application/json", ScenarioSetDecisionRequest, required: true},
    responses: @decision_responses ++ @json_errors
  )

  @doc "Approves the current intent digest."
  def approve(conn, _params), do: decide(conn, :approve)

  operation(:reject,
    summary: "Reject the current intent digest",
    description:
      "Records a `reject` decision with a required `note` (1 to 10,000 bytes). A digest " <>
        "is approved only while its latest decision is `approve`.",
    parameters: ApiParams.project() ++ @number_param ++ @source_param,
    request_body: {"Rejection", "application/json", ScenarioSetDecisionRequest, required: true},
    responses: @decision_responses ++ @json_errors
  )

  @doc "Rejects the current intent digest."
  def reject(conn, _params), do: decide(conn, :reject)

  defp decide(conn, kind) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns
    account_user = conn.assigns.current_account_user

    with {:ok, status, decision} <-
           ScenarioSets.decide(
             change_request,
             account_user,
             api_key,
             kind,
             conn.private.json_body
           ) do
      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> render(:decision, decision: decision, redact?: false)
    end
  end

  operation(:compare,
    summary: "Compare scenario set versions",
    description: """
    Compares version `to` (default current) with `from` (default: for
    `intent` the newest approved version, for `diff` the previous version)
    by scenario ID, using only section digests and priorities. Removed or
    demoted Musts (`weakening`) come first, then other removals, `changed`,
    and `added`, each by ID. With nothing to compare against, every
    scenario is `added`.
    """,
    parameters:
      ApiParams.project() ++
        @number_param ++
        @source_param ++
        [
          from: [in: :query, schema: %Schema{type: :integer, minimum: 1}, required: false],
          to: [in: :query, schema: %Schema{type: :integer, minimum: 1}, required: false]
        ],
    responses: [
      ok: {"The changes", "application/json", ScenarioSetCompareResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Compares two versions."
  def compare(conn, %{"source" => source} = params) do
    with {:ok, comparison} <-
           ScenarioSets.compare(
             conn.assigns.change_request,
             source,
             Map.take(params, ~w(from to))
           ) do
      render(conn, :compare, source: source, comparison: comparison)
    end
  end

  # Runs before the change request and body are resolved: an unknown
  # source, or a decision on a diff set, is `404`.
  defp check_source(conn, _opts) do
    case {conn.path_params["source"], action_name(conn)} do
      {"intent", _action} ->
        conn

      {"diff", action} when action in [:show, :compare] ->
        conn

      _other ->
        conn
        |> put_status(:not_found)
        |> json(GoodFlowsWeb.ErrorJSON.render("404.json", %{}))
        |> halt()
    end
  end

  defp redact?(conn), do: not ApiKey.can_write?(conn.assigns.current_api_key)
end
