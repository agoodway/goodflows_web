defmodule GoodFlowsWeb.Api.V1.RecipeController do
  @moduledoc """
  CRUD for a project's Spry recipes under `/api/v1/projects/:project/recipes`.
  The project is resolved by `GoodFlowsWeb.Plugs.LoadProject`. Reads accept
  any API key; writes require a private (`sk_`) key.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Spry
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    RecipeListResponse,
    RecipeRequest,
    RecipeResponse,
    ValidationErrorResponse
  }

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Spry"])

  @project_param ApiParams.project()
  @id_params ApiParams.recipe()

  @project_not_found {"No such project in this account", "application/json", ErrorResponse}
  @recipe_not_found ApiParams.recipe_not_found()
  @invalid_slug {"Invalid project slug", "application/json", ValidationErrorResponse}

  operation(:index,
    summary: "List a project's recipes",
    parameters: @project_param,
    responses: [
      ok: {"The project's recipes", "application/json", RecipeListResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      not_found: @project_not_found,
      unprocessable_entity: @invalid_slug
    ]
  )

  @doc "Lists the project's recipes."
  def index(conn, _params) do
    render(conn, :index,
      recipes: Spry.list_recipes(conn.assigns.current_account, conn.assigns.project)
    )
  end

  operation(:show,
    summary: "Get a recipe",
    parameters: @id_params,
    responses: [
      ok: {"The recipe", "application/json", RecipeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      not_found: @recipe_not_found,
      unprocessable_entity: @invalid_slug
    ]
  )

  @doc "Shows one recipe."
  def show(conn, %{"id" => id}) do
    with {:ok, recipe} <-
           Spry.get_recipe(conn.assigns.current_account, conn.assigns.project, id) do
      render(conn, :show, recipe: recipe)
    end
  end

  operation(:create,
    summary: "Create a recipe",
    description: """
    Replaces `spry init`. The recipe belongs to the project in the URL, which
    must already exist. Host steps, `org`, and `project` in the body are
    rejected with `422`.
    """,
    parameters: @project_param,
    request_body: {"Recipe", "application/json", RecipeRequest, required: true},
    responses: [
      created: {"The created recipe", "application/json", RecipeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: @project_not_found,
      unprocessable_entity:
        {"Invalid recipe or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Creates a recipe."
  def create(conn, _params) do
    %{current_account: account, project: project} = conn.assigns

    with {:ok, recipe} <- Spry.create_recipe(account, project, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, recipe: recipe)
    end
  end

  operation(:update,
    summary: "Replace a recipe",
    description: "Full replacement: omitted phase lists become empty. The project never changes.",
    parameters: @id_params,
    request_body: {"Recipe", "application/json", RecipeRequest, required: true},
    responses: [
      ok: {"The replaced recipe", "application/json", RecipeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: @recipe_not_found,
      unprocessable_entity:
        {"Invalid recipe or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Replaces a recipe."
  def update(conn, %{"id" => id}) do
    %{current_account: account, project: project} = conn.assigns

    with {:ok, recipe} <- Spry.replace_recipe(account, project, id, conn.body_params) do
      render(conn, :show, recipe: recipe)
    end
  end

  operation(:delete,
    summary: "Delete a recipe",
    description: "Finished runs remain retrievable by id after their recipe is deleted.",
    parameters: @id_params,
    responses: [
      no_content: "Deleted",
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: @recipe_not_found,
      conflict: {"The recipe has a queued or running run", "application/json", ConflictResponse},
      unprocessable_entity: @invalid_slug
    ]
  )

  @doc "Deletes a recipe without active runs."
  def delete(conn, %{"id" => id}) do
    with :ok <- Spry.delete_recipe(conn.assigns.current_account, conn.assigns.project, id) do
      send_resp(conn, :no_content, "")
    end
  end
end
