defmodule GoodFlowsWeb.Api.V1.SpritesCredentialController do
  @moduledoc """
  The account's Sprites API token. The token is write-only: responses report
  only whether it is configured, its last four characters, and when it changed.

  Setting or removing it requires a private (`sk_`) key whose user is an
  owner or admin of the account; other members get `403`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.Spry

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    SpritesCredentialRequest,
    SpritesCredentialStatus,
    ValidationErrorResponse
  }

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Spry"])

  operation(:show,
    summary: "Sprites credential status",
    responses: [
      ok: {"Credential status", "application/json", SpritesCredentialStatus},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse}
    ]
  )

  @doc "Reports whether a Sprites credential is configured."
  def show(conn, _params), do: render_status(conn)

  operation(:update,
    summary: "Set the Sprites credential",
    description: """
    Sets or replaces the token used for every VM operation of this account.
    Requires a private key of an account owner or admin.
    """,
    request_body: {"Token", "application/json", SpritesCredentialRequest, required: true},
    responses: [
      ok: {"Credential status", "application/json", SpritesCredentialStatus},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden:
        {"Public key, or the key's user is not an account owner or admin", "application/json",
         ErrorResponse},
      unprocessable_entity:
        {"Missing or blank token", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Sets or replaces the token."
  def update(conn, _params) do
    attrs = Map.take(conn.body_params, ["token"])

    with :ok <- require_admin(conn),
         {:ok, _credential} <- Spry.put_credential(conn.assigns.current_account, attrs) do
      render_status(conn)
    end
  end

  operation(:delete,
    summary: "Remove the Sprites credential",
    description: "Requires a private key of an account owner or admin.",
    responses: [
      no_content: "Removed (also when none was set)",
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden:
        {"Public key, or the key's user is not an account owner or admin", "application/json",
         ErrorResponse}
    ]
  )

  @doc "Removes the token."
  def delete(conn, _params) do
    with :ok <- require_admin(conn) do
      :ok = Spry.delete_credential(conn.assigns.current_account)
      send_resp(conn, :no_content, "")
    end
  end

  # The credential controls every VM operation (and billing) of the account,
  # so only owners and admins may change it.
  defp require_admin(conn) do
    if AccountUser.admin?(conn.assigns.current_account_user),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp render_status(conn) do
    json(conn, %{data: Spry.get_credential_status(conn.assigns.current_account)})
  end
end
