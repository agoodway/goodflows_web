defmodule GoodFlowsWeb.DashboardRedirectController do
  @moduledoc """
  Sends `/dashboard` to the user's default account dashboard.
  """
  use GoodFlowsWeb, :controller

  alias GoodFlows.AccountContext

  @doc "Redirects to the last-used (or first) account the user can access."
  def index(conn, _params) do
    user = conn.assigns.current_scope.user

    case AccountContext.get_default_account(user, get_session(conn)) do
      {:ok, account} ->
        redirect(conn, to: ~p"/dashboard/accounts/#{account.id}")

      {:error, :no_accounts} ->
        conn
        |> put_flash(:error, "You don't have access to any accounts. Please contact support.")
        |> redirect(to: ~p"/")
    end
  end
end
