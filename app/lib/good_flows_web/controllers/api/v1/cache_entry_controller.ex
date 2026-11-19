defmodule GoodFlowsWeb.Api.V1.CacheEntryController do
  @moduledoc """
  Remote job caches under `/api/v1/projects/:project/caches`.

  `show`, `lookup` and `reserve` are on the cache pipeline
  (`ApiAuth, :allow_cache_keys`, `LoadProject`, `RequireCacheAccess`) and
  accept `sk_` and `ck_` keys; the per-scope check
  (`GoodFlows.Accounts.ApiKey.cache_access/4`) runs here because it needs
  the request's `scope`. A key that cannot satisfy the request at all (a
  read key reserving, a bound key with another scope) gets `403` before the
  path, query or body is validated
  (`GoodFlows.Accounts.ApiKey.precheck_cache_access/4`). `index`, `delete`
  and `delete_matching` are on the project write pipeline, so only `sk_`
  keys reach them.

  Presigned URLs are credentials: nothing here logs them.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches
  alias GoodFlows.Caches.Rules
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    CacheEntryResponse,
    CacheListResponse,
    CachePurgeResponse,
    CacheReservationRequest,
    CacheReservationResponse,
    ConflictResponse,
    ErrorResponse,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema
  alias Plug.Conn.Utils

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Caches"])

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_found {"No such project in this account, or no committed entry in the lookup order",
              "application/json", ErrorResponse}

  operation(:show,
    summary: "Restore a cache entry by exact key",
    description: """
    Searches `scope` and then the project's default-branch scope (only the
    default-branch scope without `scope`), and returns the first committed
    entry with `key`. No other scope is ever read. Fetch `download_url`
    without an `Authorization` header.
    """,
    parameters: ApiParams.cache_key() ++ ApiParams.cache_scope(false),
    responses: [
      ok: {"The entry and a presigned download URL", "application/json", CacheEntryResponse},
      unauthorized: @unauthorized,
      forbidden: ApiParams.cache_forbidden(),
      not_found: @not_found,
      unprocessable_entity:
        {"Invalid `scope` or project slug", "application/json", ValidationErrorResponse},
      service_unavailable: ApiParams.cache_unavailable()
    ]
  )

  @doc "Restores an entry by exact key."
  def show(conn, %{"key" => key} = params) do
    %{current_account: account, project: project} = conn.assigns

    with :ok <- precheck(conn, params["scope"], :read),
         true <- Rules.valid_hex64?(key) || {:error, :not_found},
         {:ok, %{scope: scope}} <- Caches.validate_query(params, [:scope], []),
         :ok <- ApiKey.cache_access(conn.assigns.current_api_key, project, scope, :read),
         {:ok, entry} <- Caches.lookup_key(account, project, key, scope) do
      render(conn, :hit, entry: entry, download: Caches.download(entry))
    end
  end

  operation(:lookup,
    summary: "Restore the newest cache entry with a partial key",
    description: """
    Returns the newest committed entry (by commit time, then id) with
    `partial` in the first scope of the lookup order that has one: `scope`,
    then the default-branch scope. A newer default-branch entry never beats
    an entry in the requested scope.
    """,
    parameters:
      ApiParams.project() ++
        [
          partial: [
            in: :query,
            schema: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"},
            description: "64 lowercase hex characters. Required; any other value is `422`.",
            required: true
          ]
        ] ++ ApiParams.cache_scope(false),
    responses: [
      ok: {"The entry and a presigned download URL", "application/json", CacheEntryResponse},
      unauthorized: @unauthorized,
      forbidden: ApiParams.cache_forbidden(),
      not_found: @not_found,
      unprocessable_entity:
        {"Missing or invalid `partial`, invalid `scope`, or invalid project slug",
         "application/json", ValidationErrorResponse},
      service_unavailable: ApiParams.cache_unavailable()
    ]
  )

  @doc "Restores the newest entry with a partial key."
  def lookup(conn, params) do
    %{current_account: account, project: project} = conn.assigns

    with :ok <- precheck(conn, params["scope"], :read),
         {:ok, %{scope: scope, partial: partial}} <-
           Caches.validate_query(params, [:scope, :partial], [:partial]),
         :ok <- ApiKey.cache_access(conn.assigns.current_api_key, project, scope, :read),
         {:ok, entry} <- Caches.lookup_partial(account, project, partial, scope) do
      render(conn, :hit, entry: entry, download: Caches.download(entry))
    end
  end

  operation(:reserve,
    summary: "Reserve a cache upload",
    description: """
    Reserves `key` in `scope` and returns a presigned PUT URL with the
    headers the PUT must send exactly, without `Authorization`. Keys are
    unique per project and scope: `409` when the key is committed, or
    reserved and unexpired, in that scope. A reservation that does not fit
    the project's quota evicts the least recently used committed entries;
    `507` when unexpired reservations alone fill it.

    With `parts` (the part size and the base64 MD5 of every part), the
    server starts a multipart upload and returns `upload_parts` instead of
    `upload_url` and `upload_headers`: one presigned PUT per part, each
    with the `content-length` and `content-md5` it must send, valid until
    `upload_url_expires_at` (the reservation's lifetime). Upload parts in
    any order or in parallel, never with `Authorization`. `503` when the
    object store cannot start the upload.
    """,
    parameters: ApiParams.cache_key(),
    request_body: {"Reservation", "application/json", CacheReservationRequest, required: true},
    responses: [
      created: {"The reservation", "application/json", CacheReservationResponse},
      unauthorized: @unauthorized,
      forbidden: ApiParams.cache_forbidden(),
      not_found:
        {"No such project in this account, or a malformed path key", "application/json",
         ErrorResponse},
      conflict:
        {"The key is committed or reserved in this scope", "application/json", ConflictResponse},
      request_entity_too_large:
        {"`size` is above the entry cap", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Body is not `application/json`", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Missing, invalid or unknown body field (including `parts`), or invalid project slug",
         "application/json", ValidationErrorResponse},
      service_unavailable:
        {"No cache bucket is configured, or the object store is unavailable or cannot start a multipart upload (`retry-after: 1`)",
         "application/json", ErrorResponse},
      insufficient_storage:
        {"Unexpired reservations fill the project's quota", "application/json", ErrorResponse}
    ]
  )

  @doc "Reserves an upload."
  def reserve(conn, %{"key" => key}) do
    %{current_account: account, project: project, current_api_key: api_key} = conn.assigns

    with :ok <- precheck(conn, body_scope(conn.body_params), :write),
         :ok <- require_json(conn),
         true <- Rules.valid_hex64?(key) || {:error, :not_found},
         {:ok, reservation} <- Caches.reserve(account, project, api_key, key, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:reservation, reservation: reservation)
    end
  end

  operation(:index,
    summary: "List cache entries and usage",
    description: """
    Committed entries newest first, filtered by exact `name` and `scope`,
    keyset-paged, without download URLs. `usage` counts committed entries
    and unexpired reservations. Private keys only.
    """,
    parameters:
      ApiParams.project() ++
        [
          name: [in: :query, type: :string, description: "Exact cache name", required: false],
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
        ] ++ ApiParams.cache_scope(false),
    responses: [
      ok: {"A page of entries", "application/json", CacheListResponse},
      unauthorized: @unauthorized,
      forbidden: {"Only private keys list caches", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid filter, limit, cursor or project slug", "application/json",
         ValidationErrorResponse},
      service_unavailable: ApiParams.cache_unavailable()
    ]
  )

  @doc "Lists committed entries and the project's usage."
  def index(conn, params) do
    %{current_account: account, project: project} = conn.assigns

    with {:ok, page} <-
           Caches.list(account, project, Map.take(params, ~w(name scope limit cursor))) do
      render(conn, :index, page: page)
    end
  end

  operation(:delete,
    summary: "Purge one cache key in one scope",
    description: "Deletes the entry or reservation of `key` in `scope`. Private keys only.",
    parameters: ApiParams.cache_key() ++ ApiParams.cache_scope(true),
    responses: [
      ok: {"How many were deleted, `0` included", "application/json", CachePurgeResponse},
      unauthorized: @unauthorized,
      forbidden: {"Only private keys purge caches", "application/json", ErrorResponse},
      not_found:
        {"No such project in this account, or a malformed path key", "application/json",
         ErrorResponse},
      unprocessable_entity:
        {"Missing or invalid `scope`, or invalid project slug", "application/json",
         ValidationErrorResponse},
      service_unavailable: ApiParams.cache_unavailable()
    ]
  )

  @doc "Purges one key in one scope."
  def delete(conn, %{"key" => key} = params) do
    with {:ok, deleted} <- Caches.delete(conn.assigns.project, key, Map.take(params, ["scope"])) do
      render(conn, :purge, deleted: deleted)
    end
  end

  operation(:delete_matching,
    summary: "Purge cache entries by name, scope and partial",
    description: """
    Deletes every entry and reservation matching all of the given filters.
    At least one filter is required (`422` otherwise). Private keys only.
    """,
    parameters:
      ApiParams.project() ++
        [
          name: [in: :query, type: :string, description: "Exact cache name", required: false],
          partial: [
            in: :query,
            type: :string,
            description: "64 lowercase hex characters",
            required: false
          ]
        ] ++ ApiParams.cache_scope(false),
    responses: [
      ok: {"How many were deleted, `0` included", "application/json", CachePurgeResponse},
      unauthorized: @unauthorized,
      forbidden: {"Only private keys purge caches", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      unprocessable_entity:
        {"No filter, an invalid filter, or an invalid project slug", "application/json",
         ValidationErrorResponse},
      service_unavailable: ApiParams.cache_unavailable()
    ]
  )

  @doc "Purges every entry matching the filters."
  def delete_matching(conn, params) do
    filters = Map.take(params, ~w(name scope partial))

    with {:ok, deleted} <- Caches.delete_matching(conn.assigns.project, filters) do
      render(conn, :purge, deleted: deleted)
    end
  end

  # A key that cannot satisfy the request is refused before any validation.
  defp precheck(conn, raw_scope, access) do
    %{current_api_key: api_key, project: project} = conn.assigns
    ApiKey.precheck_cache_access(api_key, project, raw_scope, access)
  end

  # An unparsed or non-object body has no scope.
  defp body_scope(%{"scope" => scope}), do: scope
  defp body_scope(_body), do: nil

  # `RequireParsedBody` is not on the cache pipeline, and a form-encoded body
  # would parse; the reservation contract is JSON only.
  defp require_json(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _params} <- Utils.content_type(content_type) do
      :ok
    else
      _other -> {:error, :unsupported_media_type}
    end
  end
end
