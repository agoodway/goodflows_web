defmodule GoodFlowsWeb.Api.V1.CacheKeyController do
  @moduledoc """
  Mints, lists and revokes a project's cache (`ck_`) keys under
  `/api/v1/projects/:project/cache-keys`, on the project write pipeline:
  only private (`sk_`) keys. These routes work without a cache bucket.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Caches.Keys
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    CacheKeyListResponse,
    CacheKeyRequest,
    CacheKeyResponse,
    ErrorResponse,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Cache keys"])

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @forbidden {"Only private keys manage cache keys", "application/json", ErrorResponse}

  operation(:create,
    summary: "Mint a cache key",
    description: """
    Mints a `ck_` key that works only on this project's cache routes. The
    token appears only in this response. `422` when the project already has
    the most active cache keys allowed (`CACHE_MAX_KEYS_PER_PROJECT`, 1,000
    by default).
    """,
    parameters: ApiParams.project(),
    request_body: {"Cache key", "application/json", CacheKeyRequest, required: true},
    responses: [
      created: {"The key and its token", "application/json", CacheKeyResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      unsupported_media_type: ApiParams.unsupported_media_type(),
      unprocessable_entity:
        {"Invalid `access`, `scope`, `ttl_seconds` or `name`, invalid project slug, or the project's cache key cap reached",
         "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Mints a cache key."
  def create(conn, _params) do
    %{current_account_user: account_user, project: project} = conn.assigns

    with {:ok, {api_key, token}} <- Keys.mint(account_user, project, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, api_key: api_key, token: token)
    end
  end

  operation(:index,
    summary: "List cache keys",
    description: "Active (neither revoked nor expired) cache keys, newest first, without tokens.",
    parameters:
      ApiParams.project() ++
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
            description: "The `next_cursor` of the previous page. Any other value is `422`.",
            required: false
          ]
        ],
    responses: [
      ok: {"A page of keys", "application/json", CacheKeyListResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid limit, cursor or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Lists active cache keys."
  def index(conn, params) do
    with {:ok, page} <- Keys.list(conn.assigns.project, Map.take(params, ~w(limit cursor))) do
      render(conn, :index, page: page)
    end
  end

  operation(:delete,
    summary: "Revoke a cache key",
    description:
      "`204` also when already revoked; `404` for another project's key or a non-cache key.",
    parameters:
      ApiParams.project() ++
        [id: [in: :path, type: :string, description: "Cache key id", required: true]],
    responses: [
      no_content: "Revoked",
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: {"No such cache key in this project", "application/json", ErrorResponse},
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Revokes a cache key."
  def delete(conn, %{"id" => id}) do
    with :ok <- Keys.revoke(conn.assigns.project, id) do
      send_resp(conn, :no_content, "")
    end
  end
end
