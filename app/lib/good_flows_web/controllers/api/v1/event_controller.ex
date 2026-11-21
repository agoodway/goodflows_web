defmodule GoodFlowsWeb.Api.V1.EventController do
  @moduledoc """
  The project event feed, `GET /api/v1/projects/:project/events`, on the
  project read pipeline: any `sk_` or `pk_` key of the account (public
  keys get redacted events, see `GoodFlowsWeb.Api.V1.EventJSON`); `ck_`
  keys are `403`. A read with `wait` waits for the next event without
  holding a database connection (`GoodFlows.ProjectEvents.read/3`).
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ProjectEvents
  alias GoodFlowsWeb.ApiParams

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    EventsGoneResponse,
    ProjectEventListResponse,
    ValidationErrorResponse
  }

  alias OpenApiSpex.Schema

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Events"])

  operation(:index,
    summary: "Read the project event feed",
    description: """
    Events oldest first after `after` (an event `id`; omit it to start at the
    oldest kept event), up to `limit`. With `wait` (seconds) and nothing new,
    the request waits until an event commits or `wait` passes, then reads
    again. Each node allows a limited number of waiting reads per account
    (default 20); a read over the limit is answered at once as if `wait`
    were 0. Events are kept 90 days: a cursor whose following events were
    deleted is `410` with `latest_cursor`. Public keys see every `note` and
    `actor` as null.
    """,
    parameters:
      ApiParams.project() ++
        [
          after: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 0},
            description: "An event `id` (`next_cursor`)",
            required: false
          ],
          limit: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 200, default: 100},
            required: false
          ],
          wait: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 0, maximum: 30, default: 0},
            description: "Seconds to wait for a new event",
            required: false
          ]
        ],
    responses: [
      ok: {"One page of events", "application/json", ProjectEventListResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      gone:
        {"Events after `after` were deleted by retention", "application/json", EventsGoneResponse},
      unprocessable_entity:
        {"Invalid `after`, `limit`, `wait` or project slug", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Reads one page of the event feed."
  def index(conn, params) do
    %{project: project, current_account: account} = conn.assigns

    case ProjectEvents.read(project, account.id, Map.take(params, ~w(after limit wait))) do
      {:ok, page} ->
        render(conn, :index,
          events: page.events,
          next_cursor: page.next_cursor,
          redact?: not ApiKey.can_write?(conn.assigns.current_api_key)
        )

      {:error, {:gone, latest}} ->
        conn
        |> put_status(:gone)
        |> json(%{
          errors: %{detail: "Events after this cursor were deleted; resync from current state"},
          latest_cursor: latest
        })

      {:error, reason} ->
        {:error, reason}
    end
  end
end
