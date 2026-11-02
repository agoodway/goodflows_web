defmodule GoodFlowsWeb.Api.V1.RunController do
  @moduledoc """
  Starts recipe phase runs (or dry runs) and reports their progress.
  Starting and listing a recipe's runs live under
  `/api/v1/projects/:project/recipes/:id/runs` and require the recipe to
  belong to that project; `GET /api/v1/runs/:id` stays account-scoped.
  Starting requires a private (`sk_`) key; reading accepts any key, but
  public (`pk_`) keys never see step `command` or `output`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Spry
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    RunConflictResponse,
    RunListResponse,
    RunPlan,
    RunRequest,
    RunResponse,
    ValidationErrorResponse
  }

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Spry"])

  @recipe_params ApiParams.recipe()
  @recipe_not_found ApiParams.recipe_not_found()

  operation(:create,
    summary: "Start a run",
    description: """
    Runs a recipe phase (`setup`, `start`, `stop`, or `teardown`) against the
    resolved sprite asynchronously and returns the queued run (`202`). Poll
    `GET /api/v1/runs/{id}` for progress. With a true `dry_run` (any boolean
    form, e.g. `true`, `"true"`, `"1"`), returns the expanded plan (`200`)
    without creating a run or touching the VM. A dry run still requires a
    private key: it uses the stored Sprites credential to look up the VM.

    Inputs are inserted unquoted into shell lines, so each is restricted:
    `branch` and `commit` (letters, digits, `. _ / + -`, at most 255
    characters), `remote` (letters, digits, `. _ : / @ % + -`, at most 1024),
    each starting with a letter or digit. The expanded sprite
    name must be lowercase letters, digits, and hyphens (starting with a
    letter or digit, at most 63 characters); prefer `{{branch_slug}}` over
    `{{branch}}` in names. Violations are `422`.
    """,
    parameters: @recipe_params,
    request_body: {"Run request", "application/json", RunRequest, required: true},
    responses: [
      unsupported_media_type: ApiParams.unsupported_media_type(),
      ok: {"Dry-run plan", "application/json", RunPlan},
      accepted: {"The queued run", "application/json", RunResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot start runs", "application/json", ErrorResponse},
      not_found: @recipe_not_found,
      conflict:
        {"A run is already active for this sprite", "application/json", RunConflictResponse},
      unprocessable_entity:
        {"Invalid request, missing input, missing credential, or invalid project slug",
         "application/json", ValidationErrorResponse},
      service_unavailable:
        {"The run could not be queued, or admission was contended; retry", "application/json",
         ErrorResponse}
    ]
  )

  @doc "Starts a run, or returns its plan when the cast `dry_run` flag is true."
  def create(conn, %{"id" => recipe_id}) do
    %{current_account: account, project: project} = conn.assigns
    params = Map.drop(conn.body_params, ["id"])
    opts = [started_by_api_key_id: conn.assigns.current_api_key.id]

    case Spry.request_run(account, project, recipe_id, params, opts) do
      {:ok, {:plan, result}} ->
        render(conn, :plan, result)

      {:ok, {:run, run}} ->
        conn
        |> put_status(:accepted)
        |> render(:show, run: run, full_steps?: true)

      {:error, _reason} = error ->
        error
    end
  end

  operation(:index,
    summary: "List a recipe's runs",
    description: """
    Newest first, without steps or output, one page at a time (keyset
    pagination on creation time and id). Pass the response's `next_cursor`
    as `cursor` to get the next page; it is `null` on the last page.
    """,
    parameters:
      @recipe_params ++
        [
          limit: [
            in: :query,
            schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
            description: "Page size (1 to 200, default 50)",
            required: false
          ],
          cursor: [
            in: :query,
            type: :string,
            description: "The `next_cursor` of the previous page",
            required: false
          ]
        ],
    responses: [
      ok: {"Runs", "application/json", RunListResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      not_found: @recipe_not_found,
      unprocessable_entity:
        {"Invalid limit, cursor, or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Lists one page of a recipe's runs, newest first."
  def index(conn, %{"id" => recipe_id} = params) do
    page_params = Map.take(params, ["limit", "cursor"])

    %{current_account: account, project: project} = conn.assigns

    with {:ok, page} <- Spry.list_runs(account, project, recipe_id, page_params) do
      render(conn, :index, runs: page.runs, next_cursor: page.next_cursor)
    end
  end

  operation(:show,
    summary: "Get a run",
    description: """
    Status, inputs, any run-level error, and each step. Step `command` and
    `output` are included only for private (`sk_`) keys; public keys get
    every other step field.
    """,
    parameters: [id: [in: :path, type: :string, description: "Run ID", required: true]],
    responses: [
      ok: {"The run with steps", "application/json", RunResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      not_found: {"No such run in this account", "application/json", ErrorResponse}
    ]
  )

  @doc "Shows a run with its steps."
  def show(conn, %{"id" => id}) do
    with {:ok, run} <- Spry.get_run(conn.assigns.current_account, id) do
      render(conn, :show, run: run, full_steps?: ApiKey.can_write?(conn.assigns.current_api_key))
    end
  end
end
