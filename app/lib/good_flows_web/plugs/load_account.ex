defmodule GoodFlowsWeb.Plugs.LoadAccount do
  @moduledoc """
  Loads the account named by the `account_id` path param, verifying the
  current user is a member, and remembers it as the session's
  `last_account_id`. Must run after `:require_authenticated_user`.
  """
  @behaviour Plug

  import Plug.Conn

  alias GoodFlows.AccountContext

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    user = conn.assigns.current_scope.user

    case AccountContext.get_account_for_user(user, conn.params["account_id"]) do
      {:ok, account} ->
        conn
        |> assign(:current_account, account)
        |> put_session(:last_account_id, account.id)

      {:error, :not_found} ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Unable to access this account.")
        |> Phoenix.Controller.redirect(to: "/dashboard")
        |> halt()
    end
  end
end
