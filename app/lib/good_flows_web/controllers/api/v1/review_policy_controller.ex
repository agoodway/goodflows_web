defmodule GoodFlowsWeb.Api.V1.ReviewPolicyController do
  @moduledoc """
  The project's versioned review policy under
  `/api/v1/projects/:project/review-policy`.

  Reads are on the project read pipeline: any `sk_` or `pk_` key of the
  account (public keys see `note` and `written_by` as null). The write is
  on the project write pipeline, and an `sk_` key whose membership is not
  owner or admin is `403` before `GoodFlowsWeb.Plugs.JsonBody` reads the
  body (like `GoodFlowsWeb.Api.V1.SpritesCredentialController`).
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ReviewPolicies
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest}

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    ReviewPolicyResponse,
    ReviewPolicyVersionListResponse,
    ReviewPolicyWriteRequest,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema

  plug :require_admin when action in [:update]
  plug JsonBody, [limit: :review_policy_max_body_bytes, default: 262_144] when action in [:update]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Review policy"])

  @read_errors [
    unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
    forbidden: {"Cache keys", "application/json", ErrorResponse},
    not_found: {"No such project in this account", "application/json", ErrorResponse},
    not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  ]

  operation(:show,
    summary: "Read the current review policy",
    description: "The newest version, or the default version 0 when the project never wrote one.",
    parameters: ApiParams.project(),
    responses:
      [
        ok: {"The current version", "application/json", ReviewPolicyResponse},
        unprocessable_entity:
          {"Invalid project slug", "application/json", ValidationErrorResponse}
      ] ++ @read_errors
  )

  @doc "Shows the current version."
  def show(conn, _params) do
    render(conn, :show,
      version: ReviewPolicies.current(conn.assigns.project),
      redact?: redact?(conn)
    )
  end

  operation(:index,
    summary: "List review policy versions",
    description: "Stored versions newest first (version 0 is never listed), keyset-paged.",
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
    responses:
      [
        ok: {"One page of versions", "application/json", ReviewPolicyVersionListResponse},
        unprocessable_entity:
          {"Invalid limit, cursor or project slug", "application/json", ValidationErrorResponse}
      ] ++ @read_errors
  )

  @doc "Lists one page of versions."
  def index(conn, params) do
    with {:ok, page} <-
           ReviewPolicies.list_versions(conn.assigns.project, Map.take(params, ~w(limit cursor))) do
      render(conn, :index,
        versions: page.versions,
        next_cursor: page.next_cursor,
        redact?: redact?(conn)
      )
    end
  end

  operation(:show_version,
    summary: "Show a review policy version",
    parameters:
      ApiParams.project() ++
        [version: [in: :path, type: :integer, description: "Version number", required: true]],
    responses:
      [
        ok: {"The version", "application/json", ReviewPolicyResponse},
        unprocessable_entity:
          {"Invalid version or project slug", "application/json", ValidationErrorResponse}
      ] ++
        Keyword.put(
          @read_errors,
          :not_found,
          {"No such project or version", "application/json", ErrorResponse}
        )
  )

  @doc "Shows one version."
  def show_version(conn, %{"version" => version}) do
    number =
      case version do
        "0" -> {:ok, 0}
        other -> LoadChangeRequest.parse(other)
      end

    with {:number, {:ok, number}} <- {:number, number},
         {:ok, found} <- ReviewPolicies.get_version(conn.assigns.project, number) do
      render(conn, :show, version: found, redact?: redact?(conn))
    else
      {:number, :invalid} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{"version" => ["must be a nonnegative integer"]}})

      {:error, _reason} = error ->
        error
    end
  end

  operation(:update,
    summary: "Write a review policy version",
    description: """
    Stores version `previous_version + 1` when `previous_version` is the
    current version (`201`). A retry with the previous version and the
    current version's `policy` and `note` is `200` with the current
    version; any other `previous_version` is `409`. Requires a private key
    of an account owner or admin; others get `403` before the body is
    read. Every `draft` and `open` change request of the project is
    recomputed with the new version. The body is strict JSON of at most
    256 KiB.
    """,
    parameters: ApiParams.project(),
    request_body: {"Policy write", "application/json", ReviewPolicyWriteRequest, required: true},
    responses: [
      created: {"The new version", "application/json", ReviewPolicyResponse},
      ok: {"Exact retry of the current version", "application/json", ReviewPolicyResponse},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      forbidden:
        {"Public or cache key, or the key's user is not an owner or admin", "application/json",
         ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      conflict:
        {"`previous_version` is not the current version", "application/json", ConflictResponse},
      request_entity_too_large: {"Body exceeds 256 KiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid body or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Writes a new version."
  def update(conn, _params) do
    %{project: project, current_account_user: account_user, current_api_key: api_key} =
      conn.assigns

    with {:ok, status, version} <-
           ReviewPolicies.write(project, account_user, api_key, conn.private.json_body) do
      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> render(:show, version: version, redact?: false)
    end
  end

  defp require_admin(conn, _opts) do
    if AccountUser.admin?(conn.assigns.current_account_user) do
      conn
    else
      conn |> GoodFlowsWeb.FallbackController.call({:error, :forbidden}) |> halt()
    end
  end

  defp redact?(conn), do: not ApiKey.can_write?(conn.assigns.current_api_key)
end
