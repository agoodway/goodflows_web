defmodule GoodFlowsWeb.Api.V1.PoolController do
  @moduledoc """
  CRUD for a project's Sprite pools under `/api/v1/projects/:project/pools`.
  The project is resolved by `GoodFlowsWeb.Plugs.LoadProject`. Reads accept
  any API key; writes require a private (`sk_`) key. Every route answers
  `503` while pools are disabled (`GoodFlowsWeb.Plugs.PoolsEnabled`), except
  `delete`, which stays available so a rollback can be cleaned up.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Pools
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    PoolListResponse,
    PoolMemberListResponse,
    PoolRequest,
    PoolResponse,
    ValidationErrorResponse
  }

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Pools"])

  @project_param ApiParams.project()
  @pool_params ApiParams.pool()

  @unauthorized {"Missing or invalid API key", "application/json", ErrorResponse}
  @forbidden {"Public keys cannot write", "application/json", ErrorResponse}
  @project_not_found {"No such project in this account", "application/json", ErrorResponse}
  @pool_not_found {"No such project in this account, or no such pool in this project",
                   "application/json", ErrorResponse}
  @invalid_slug {"Invalid project slug", "application/json", ValidationErrorResponse}
  @invalid_pool {"Invalid pool body or project slug, or no Sprites credential",
                 "application/json", ValidationErrorResponse}

  operation(:index,
    summary: "List a project's pools",
    description: "Ordered by `slug`. Pools being deleted are not listed.",
    parameters: @project_param,
    responses: [
      ok: {"The project's pools", "application/json", PoolListResponse},
      unauthorized: @unauthorized,
      not_found: @project_not_found,
      unprocessable_entity: @invalid_slug,
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Lists the project's pools."
  def index(conn, _params) do
    render(conn, :index,
      pools: Pools.list_pools(conn.assigns.current_account, conn.assigns.project)
    )
  end

  operation(:show,
    summary: "Get a pool",
    parameters: @pool_params,
    responses: [
      ok: {"The pool", "application/json", PoolResponse},
      unauthorized: @unauthorized,
      not_found: @pool_not_found,
      unprocessable_entity: @invalid_slug,
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Shows one pool."
  def show(conn, %{"pool" => slug}) do
    with {:ok, pool} <- Pools.get_pool(conn.assigns.current_account, conn.assigns.project, slug) do
      render(conn, :show, pool: pool)
    end
  end

  operation(:create,
    summary: "Create a pool",
    description: """
    Creates a pool of Sprite VMs in the project. The account needs a Sprites
    credential (`422` otherwise, after body validation). Members are
    provisioned in the background up to `min_ready`.
    """,
    parameters: @project_param,
    request_body: {"Pool", "application/json", PoolRequest, required: true},
    responses: [
      unsupported_media_type: ApiParams.unsupported_media_type(),
      created: {"The created pool", "application/json", PoolResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @project_not_found,
      unprocessable_entity: @invalid_pool,
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Creates a pool."
  def create(conn, _params) do
    %{current_account: account, project: project} = conn.assigns

    with {:ok, pool} <- Pools.create_pool(account, project, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, pool: pool)
    end
  end

  operation(:update,
    summary: "Replace a pool",
    description: """
    Full replacement; the body `slug` must equal the URL's. Changing `setup`
    increments `setup_version`: idle members built from the old setup are
    destroyed and replaced, and leased ones after their session releases
    them. Changing only `min_ready` or `max_members` keeps `setup_version`.
    """,
    parameters: @pool_params,
    request_body: {"Pool", "application/json", PoolRequest, required: true},
    responses: [
      unsupported_media_type: ApiParams.unsupported_media_type(),
      ok: {"The replaced pool", "application/json", PoolResponse},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @pool_not_found,
      unprocessable_entity: @invalid_pool,
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Replaces a pool."
  def update(conn, %{"pool" => slug}) do
    %{current_account: account, project: project} = conn.assigns

    with {:ok, pool} <- Pools.replace_pool(account, project, slug, conn.body_params) do
      render(conn, :show, pool: pool)
    end
  end

  operation(:delete,
    summary: "Delete a pool",
    description: """
    `202`: the pool disappears at once and its member sprites are destroyed
    in the background before its record is removed (the project cannot be
    deleted until then). `409` while any session of the pool is waiting or
    active. Unlike every other pool route, deletion also works while pools
    are disabled, so a rollback can be cleaned up. A member whose sprite can
    never be destroyed (its creation credential was revoked) is `abandoned`
    and forgotten when the pool is removed.
    """,
    parameters: @pool_params,
    responses: [
      accepted: "Deletion started",
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @pool_not_found,
      conflict: {"The pool has waiting or active sessions", "application/json", ConflictResponse},
      unprocessable_entity: @invalid_slug
    ]
  )

  @doc "Starts deleting a pool."
  def delete(conn, %{"pool" => slug}) do
    with :ok <- Pools.delete_pool(conn.assigns.current_account, conn.assigns.project, slug) do
      send_resp(conn, :accepted, "")
    end
  end

  operation(:members,
    summary: "List a pool's members",
    parameters: @pool_params,
    responses: [
      ok: {"The pool's members", "application/json", PoolMemberListResponse},
      unauthorized: @unauthorized,
      not_found: @pool_not_found,
      unprocessable_entity: @invalid_slug,
      service_unavailable: ApiParams.pools_disabled()
    ]
  )

  @doc "Lists a pool's members."
  def members(conn, %{"pool" => slug}) do
    with {:ok, pool, members} <-
           Pools.list_members(conn.assigns.current_account, conn.assigns.project, slug) do
      render(conn, :members, pool: pool, members: members)
    end
  end
end
