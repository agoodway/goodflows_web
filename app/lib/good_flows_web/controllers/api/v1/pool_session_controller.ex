defmodule GoodFlowsWeb.Api.V1.PoolSessionController do
  @moduledoc """
  Pool sessions: `POST /api/v1/projects/:project/pools/:pool/sessions`
  (private key), `GET /api/v1/pool-sessions/:id` (any key of the account),
  and `DELETE /api/v1/pool-sessions/:id` (the creating key). Execs run
  over the `pool_session:<id>` channel on `/api/v1/socket`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Pools.Sessions
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    PoolSessionRequest,
    PoolSessionResponse,
    ValidationErrorResponse
  }

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Pools"])

  @id_param [id: [in: :path, type: :string, description: "Session ID", required: true]]
  @unauthorized {"Missing or invalid API key", "application/json", ErrorResponse}

  operation(:create,
    summary: "Start a pool session",
    description: """
    Starts a session in status `waiting` and returns it with its channel
    `topic`. Members are granted partially and fairly as they become idle;
    join the topic on `/api/v1/socket` to receive grants, upload the
    workspace with `PUT /api/v1/pool-sessions/{id}/workspace`, run execs,
    and release. The session captures the account's Sprites credential
    (`422` without one) and belongs to the creating key.
    """,
    parameters: ApiParams.pool(),
    request_body: {"Session", "application/json", PoolSessionRequest, required: true},
    responses: [
      unsupported_media_type: ApiParams.unsupported_media_type(),
      created: {"The session", "application/json", PoolSessionResponse},
      unauthorized: @unauthorized,
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found:
        {"No such project, or no such pool in the project (or it is being deleted)",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid body or project slug, or no Sprites credential", "application/json",
         ValidationErrorResponse},
      service_unavailable:
        {"Pools are disabled or this node is draining", "application/json", ErrorResponse}
    ]
  )

  @doc "Starts a session."
  def create(conn, %{"pool" => pool_slug}) do
    %{current_account: account, project: project, current_api_key: key} = conn.assigns

    with {:ok, session} <- Sessions.create(account, project, pool_slug, key, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, session: session, members: Sessions.members(session.id))
    end
  end

  operation(:show,
    summary: "Get a pool session",
    description: "Any key of the account may read a session.",
    parameters: @id_param,
    responses: [
      ok: {"The session", "application/json", PoolSessionResponse},
      unauthorized: @unauthorized,
      not_found: {"No such session in this account", "application/json", ErrorResponse},
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Shows a session."
  def show(conn, %{"id" => id}) do
    with {:ok, session} <- Sessions.get(conn.assigns.current_account, id) do
      render(conn, :show, session: session, members: Sessions.members(session.id))
    end
  end

  operation(:delete,
    summary: "Release a pool session",
    description: """
    Ends the session as `released`: running execs are cancelled and its
    members reset. Releasing an ended session is `204` and changes nothing.
    Only the creating key may release (`403` for another key).
    """,
    parameters: @id_param,
    responses: [
      no_content: "Released",
      unauthorized: @unauthorized,
      forbidden: {"Another key created the session", "application/json", ErrorResponse},
      not_found: {"No such session in this account", "application/json", ErrorResponse},
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Releases a session (idempotent)."
  def delete(conn, %{"id" => id}) do
    %{current_account: account, current_api_key: key} = conn.assigns

    with {:ok, session} <- Sessions.get_owned(account, key, id) do
      :ok = Sessions.release(session)
      send_resp(conn, :no_content, "")
    end
  end
end
