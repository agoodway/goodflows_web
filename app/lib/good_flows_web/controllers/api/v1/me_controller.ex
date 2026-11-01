defmodule GoodFlowsWeb.Api.V1.MeController do
  @moduledoc """
  Describes the credentials behind an API request. Useful for checking that
  a key works and which account it is scoped to.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlowsWeb.Schemas.{ErrorResponse, MeResponse}

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Identity"])

  operation(:show,
    summary: "Current credentials",
    description: "Returns the account, user, role, and API key the request authenticated as.",
    responses: [
      ok: {"Current credentials", "application/json", MeResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse}
    ]
  )

  @doc "Renders the authenticated account, user, role, and API key."
  def show(conn, _params) do
    %{current_api_key: api_key, current_account_user: account_user} = conn.assigns
    %{account: account, user: user} = account_user

    json(conn, %{
      data: %{
        account: %{id: account.id, name: account.name, slug: account.slug},
        user: %{id: user.id, email: user.email},
        role: account_user.role,
        api_key: %{
          id: api_key.id,
          name: api_key.name,
          type: api_key.type,
          token_prefix: api_key.token_prefix,
          expires_at: api_key.expires_at
        }
      }
    })
  end
end
