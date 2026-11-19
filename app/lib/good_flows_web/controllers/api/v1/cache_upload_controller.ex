defmodule GoodFlowsWeb.Api.V1.CacheUploadController do
  @moduledoc """
  Commits cache uploads (`POST /api/v1/projects/:project/caches/uploads/:upload_id/commit`)
  on the cache pipeline. Only the API key that reserved an upload may
  commit it.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches
  alias GoodFlowsWeb.Api.V1.CacheEntryJSON
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Schemas.{CacheEntryResponse, ErrorResponse, ValidationErrorResponse}

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Caches"])

  operation(:commit,
    summary: "Commit a cache upload",
    description: """
    Makes a reservation visible after checking that the stored object exists
    and that its length and recorded SHA-256 match the reservation. When a
    check fails the reservation is deleted and the response is `422` on
    `upload`. Committing an upload this key already committed is `200`
    again. There is no body.

    For a reservation with `parts`, the server lists the uploaded parts
    from the store (client ETags are never used): every part must be
    present with an ETag equal to the hex of its declared MD5 and its
    declared length. It then completes the upload and checks the object's
    length and multipart ETag. A failed check deletes the reservation,
    aborts the upload and is `422` on `upload`. The entry's `sha256` is the
    declared value, not verified by the store. Completing many parts can
    take up to about two minutes; `503` keeps the reservation and the
    commit can be retried.
    """,
    parameters:
      ApiParams.project() ++
        [
          upload_id: [
            in: :path,
            type: :string,
            description:
              "The reservation's `upload_id`, a lowercase UUID. Other values are `404`.",
            required: true
          ]
        ],
    responses: [
      ok: {"The committed entry", "application/json", CacheEntryResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      forbidden: ApiParams.cache_forbidden(),
      not_found:
        {"No such upload in this project, expired, or reserved by another key",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"The object is missing, has missing or wrong parts, or has the wrong size or checksum (on `upload`)",
         "application/json", ValidationErrorResponse},
      service_unavailable: ApiParams.cache_unavailable()
    ]
  )

  @doc "Commits an upload."
  def commit(conn, %{"upload_id" => upload_id}) do
    %{project: project, current_api_key: api_key} = conn.assigns

    # A key reserves only in its bound scope, so committing needs write
    # access to that scope; a read key is refused before any lookup.
    with :ok <- ApiKey.precheck_cache_access(api_key, project, api_key.scope, :write),
         {:ok, entry} <- Caches.commit(project, api_key, upload_id) do
      conn
      |> put_view(json: CacheEntryJSON)
      |> render(:hit, entry: entry, download: Caches.download(entry))
    end
  end
end
