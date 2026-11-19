defmodule GoodFlowsWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer token authentication for JSON API requests.

      plug GoodFlowsWeb.Plugs.ApiAuth                         # any valid pk_ or sk_ key
      plug GoodFlowsWeb.Plugs.ApiAuth, :allow_cache_keys      # also ck_ keys (cache routes)
      plug GoodFlowsWeb.Plugs.ApiAuth, :require_write_access  # private sk_ keys only

  The default clause refuses cache (`ck_`) keys with `403`, so every route
  outside the cache routes refuses them without a change of its own.

  On success assigns `:current_api_key`, `:current_account_user`,
  `:current_account`, and `:current_scope` (for the key's user).
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{ApiKey, Scope}
  alias GoodFlowsWeb.ErrorJSON
  alias Plug.Conn.Status

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, :require_write_access), do: require_write_access(conn, [])
  def call(conn, :allow_cache_keys), do: require_api_auth(conn, [])

  def call(conn, opts) do
    conn = require_api_auth(conn, opts)

    if not conn.halted and ApiKey.cache_key?(conn.assigns.current_api_key),
      do: halt_with(conn, :forbidden),
      else: conn
  end

  @doc """
  Authenticates the request from its `Authorization: Bearer <token>` header,
  halting with 401 when the token is missing, unknown, revoked, or expired.
  """
  @spec require_api_auth(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_api_auth(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, api_key} <- Accounts.verify_api_token(token) do
      {:ok, api_key} = Accounts.touch_api_key(api_key)
      account_user = api_key.account_user

      conn
      |> assign(:current_api_key, api_key)
      |> assign(:current_account_user, account_user)
      |> assign(:current_account, account_user.account)
      |> assign(:current_scope, Scope.for_user(account_user.user))
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> halt_with(:unauthorized)
    end
  end

  @doc """
  Halts with 403 unless the authenticated key is a private (`sk_`) key.
  Must run after `require_api_auth/2`.
  """
  @spec require_write_access(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_write_access(conn, _opts) do
    case conn.assigns[:current_api_key] do
      %ApiKey{} = api_key ->
        if ApiKey.can_write?(api_key), do: conn, else: halt_with(conn, :forbidden)

      nil ->
        halt_with(conn, :forbidden)
    end
  end

  defp halt_with(conn, status) do
    code = Status.code(status)

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{code}.json", %{}))
    |> halt()
  end
end
