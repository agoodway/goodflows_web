defmodule GoodFlowsWeb.Api.V1.FeatureIndexController do
  @moduledoc """
  The project's feature index under `/api/v1/projects/:project/feature-index`.

  Any `sk_` key of the account syncs (project write pipeline); `sk_` and
  `pk_` keys read. `ck_` keys are `403`. The body is strict JSON read after
  the project is resolved.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.FeatureIndex
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest}

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    FeatureIndexResponse,
    FeatureIndexSyncRequest,
    FeatureIndexVersionListResponse,
    ValidationErrorResponse
  }

  plug JsonBody,
       [limit: :feature_index_max_body_bytes, default: 1_048_576] when action in [:create]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Feature index"])

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  @read_forbidden {"Cache keys", "application/json", ErrorResponse}

  operation(:create,
    summary: "Sync the feature index",
    description: """
    Uploads every feature (1 to 500) with its `paths` globs (review policy
    glob rules). Features that differ from the newest version create the
    next version (`201`) and recompute every `draft` and `open` change
    request of the project; equal features (as a JSON value) are `200`
    with `duplicate` true. Any private key may sync. Strict JSON, 1 MiB.
    """,
    parameters: ApiParams.project(),
    request_body: {"Features", "application/json", FeatureIndexSyncRequest, required: true},
    responses: [
      created: {"New version", "application/json", FeatureIndexResponse},
      ok: {"Equal to the newest version", "application/json", FeatureIndexResponse},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden: {"Public or cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      request_entity_too_large: {"Body exceeds 1 MiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid body or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Syncs the feature index."
  def create(conn, _params) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with {:ok, status, version} <- FeatureIndex.sync(project, api_key, conn.private.json_body) do
      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> render(:sync, version: version, duplicate: status == :duplicate)
    end
  end

  operation(:show,
    summary: "Show the current feature index",
    description: "The newest version, or `404` when the project has never synced.",
    parameters: ApiParams.project(),
    responses: [
      ok: {"The current version", "application/json", FeatureIndexResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: {"No such project, or never synced", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Shows the current version."
  def show(conn, _params) do
    with {:ok, version} <- FeatureIndex.current(conn.assigns.project) do
      render(conn, :show, version: version)
    end
  end

  operation(:index,
    summary: "List feature index versions",
    description: "Newest first with `version`, `inserted_at` and `feature_count`, keyset-paged.",
    parameters: ApiParams.project() ++ ApiParams.version_page(),
    responses: [
      ok: {"One page of versions", "application/json", FeatureIndexVersionListResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid limit, cursor or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Lists versions."
  def index(conn, params) do
    with {:ok, page} <-
           FeatureIndex.list_versions(conn.assigns.project, Map.take(params, ~w(limit cursor))) do
      render(conn, :index, versions: page.versions, next_cursor: page.next_cursor)
    end
  end

  operation(:show_version,
    summary: "Show a feature index version",
    parameters:
      ApiParams.project() ++
        [version: [in: :path, type: :integer, description: "Version number", required: true]],
    responses: [
      ok: {"The version", "application/json", FeatureIndexResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: {"No such project or version", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Shows one version."
  def show_version(conn, %{"version" => version}) do
    with {:ok, number} <- parse(version),
         {:ok, found} <- FeatureIndex.get_version(conn.assigns.project, number) do
      render(conn, :show, version: found)
    end
  end

  defp parse(value) do
    case LoadChangeRequest.parse(value) do
      {:ok, number} -> {:ok, number}
      :invalid -> {:error, :not_found}
    end
  end
end
