defmodule GoodFlowsWeb.Api.V1.RecipeController do
  @moduledoc """
  CRUD for the account's Spry recipes. Reads accept any API key; writes
  require a private (`sk_`) key.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Spry

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

  @id_param [id: [in: :path, type: :string, description: "Recipe ID", required: true]]

  operation(:index,
    summary: "List recipes",
    responses: [
      ok: {"The account's recipes", "application/json", RecipeListResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse}
    ]
  )

  @doc "Lists the account's recipes."
  def index(conn, _params) do
    render(conn, :index, recipes: Spry.list_recipes(conn.assigns.current_account))
  end

  operation(:show,
    summary: "Get a recipe",
    parameters: @id_param,
    responses: [
      ok: {"The recipe", "application/json", RecipeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      not_found: {"No such recipe in this account", "application/json", ErrorResponse}
    ]
  )

  @doc "Shows one recipe."
  def show(conn, %{"id" => id}) do
    with {:ok, recipe} <- Spry.get_recipe(conn.assigns.current_account, id) do
      render(conn, :show, recipe: recipe)
    end
  end

  operation(:create,
    summary: "Create a recipe",
    description: "Replaces `spry init`. Host steps and `org` are rejected with `422`.",
    request_body: {"Recipe", "application/json", RecipeRequest, required: true},
    responses: [
      created: {"The created recipe", "application/json", RecipeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      unprocessable_entity: {"Invalid recipe", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Creates a recipe."
  def create(conn, _params) do
    with {:ok, recipe} <- Spry.create_recipe(conn.assigns.current_account, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, recipe: recipe)
    end
  end

  operation(:update,
    summary: "Replace a recipe",
    description: "Full replacement: omitted phase lists become empty.",
    parameters: @id_param,
    request_body: {"Recipe", "application/json", RecipeRequest, required: true},
    responses: [
      ok: {"The replaced recipe", "application/json", RecipeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such recipe in this account", "application/json", ErrorResponse},
      unprocessable_entity: {"Invalid recipe", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Replaces a recipe."
  def update(conn, %{"id" => id}) do
    with {:ok, recipe} <-
           Spry.replace_recipe(conn.assigns.current_account, id, conn.body_params) do
      render(conn, :show, recipe: recipe)
    end
  end

  operation(:delete,
    summary: "Delete a recipe",
    description: "Finished runs remain retrievable by id after their recipe is deleted.",
    parameters: @id_param,
    responses: [
      no_content: "Deleted",
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such recipe in this account", "application/json", ErrorResponse},
      conflict: {"The recipe has a queued or running run", "application/json", ConflictResponse}
    ]
  )

  @doc "Deletes a recipe without active runs."
  def delete(conn, %{"id" => id}) do
    with :ok <- Spry.delete_recipe(conn.assigns.current_account, id) do
      send_resp(conn, :no_content, "")
    end
  end
end
