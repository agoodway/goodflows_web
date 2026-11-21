defmodule GoodFlowsWeb.Api.V1.ProjectController do
  @moduledoc """
  Create, list, show, update, and delete the account's projects. Reads
  accept any API key; writes require a private (`sk_`) key. `PATCH`
  changes only `default_branch`; there is no rename: the slug is the
  project's public name.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Projects
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    ProjectListResponse,
    ProjectRequest,
    ProjectResponse,
    ProjectUpdateRequest,
    ValidationErrorResponse
  }

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Projects"])

  @project_param ApiParams.project()

  operation(:index,
    summary: "List projects",
    description: "The account's projects, ordered by `slug`.",
    responses: [
      ok: {"The account's projects", "application/json", ProjectListResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse}
    ]
  )

  @doc "Lists the account's projects ordered by slug."
  def index(conn, _params) do
    render(conn, :index, projects: Projects.list_projects(conn.assigns.current_account))
  end

  operation(:create,
    summary: "Create a project",
    request_body: {"Project", "application/json", ProjectRequest, required: true},
    responses: [
      unsupported_media_type: ApiParams.unsupported_media_type(),
      created: {"The created project", "application/json", ProjectResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid or duplicate slug, or invalid `default_branch`", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Creates a project."
  def create(conn, _params) do
    attrs = Map.take(conn.body_params, ["slug", "default_branch"])

    with {:ok, project} <- Projects.create_project(conn.assigns.current_account, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, project: project)
    end
  end

  operation(:show,
    summary: "Get a project",
    parameters: @project_param,
    responses: [
      ok: {"The project", "application/json", ProjectResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Shows the project loaded by `GoodFlowsWeb.Plugs.LoadProject`."
  def show(conn, _params) do
    render(conn, :show, project: conn.assigns.project)
  end

  operation(:update,
    summary: "Change a project's default branch",
    description: """
    Accepts only `default_branch`, the project's fallback cache scope. Any
    other key, `slug` included, is `422`: a project cannot be renamed.
    Changing `default_branch` changes only which scope later cache lookups
    fall back to. It moves or deletes no cache entry.
    """,
    parameters: @project_param,
    request_body: {"Project update", "application/json", ProjectUpdateRequest, required: true},
    responses: [
      ok: {"The updated project", "application/json", ProjectResponse},
      unsupported_media_type: ApiParams.unsupported_media_type(),
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid `default_branch`, an unknown key, or an invalid project slug",
         "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Updates the project's `default_branch`; any other body key is `422`."
  def update(conn, _params) do
    body = conn.body_params

    case Map.keys(body) -- ["default_branch"] do
      [] ->
        with {:ok, project} <-
               Projects.update_project(conn.assigns.current_account, conn.assigns.project, body) do
          render(conn, :show, project: project)
        end

      unknown ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Map.new(unknown, &{&1, ["is not allowed"]})})
    end
  end

  operation(:delete,
    summary: "Delete a project",
    description:
      "Only a project without recipes, test reports, workflow runs, change requests " <>
        "(in any state) or verify runs (in any status) can be deleted; otherwise `409`. " <>
        "Cache entries, cache keys, review policy versions and feature index versions are " <>
        "deleted with the project.",
    parameters: @project_param,
    responses: [
      no_content: "Deleted",
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      conflict:
        {"The project still has recipes, test reports, workflow runs, change requests or " <>
           "verify runs", "application/json", ConflictResponse},
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Deletes a project that has no recipes or test reports."
  def delete(conn, _params) do
    with :ok <- Projects.delete_project(conn.assigns.current_account, conn.assigns.project) do
      send_resp(conn, :no_content, "")
    end
  end
end
