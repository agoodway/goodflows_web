defmodule GoodFlowsWeb.Api.V1.ProjectController do
  @moduledoc """
  Create, list, show, and delete the account's projects. Reads accept any
  API key; writes require a private (`sk_`) key. There is no update or
  rename route: the slug is the project's public name.
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
      created: {"The created project", "application/json", ProjectResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid or duplicate slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Creates a project."
  def create(conn, _params) do
    attrs = Map.take(conn.body_params, ["slug"])

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

  operation(:delete,
    summary: "Delete a project",
    description: "Only a project without recipes can be deleted; otherwise `409`.",
    parameters: @project_param,
    responses: [
      no_content: "Deleted",
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      conflict: {"The project still has recipes", "application/json", ConflictResponse},
      unprocessable_entity: {"Invalid project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Deletes a project that has no recipes."
  def delete(conn, _params) do
    with :ok <- Projects.delete_project(conn.assigns.current_account, conn.assigns.project) do
      send_resp(conn, :no_content, "")
    end
  end
end
