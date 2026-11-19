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
        {"The object is missing or has the wrong size or checksum (on `upload`)",
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
