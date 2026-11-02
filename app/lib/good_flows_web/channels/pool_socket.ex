defmodule GoodFlowsWeb.PoolSocket do
  @moduledoc """
  Phoenix Channels v2 WebSocket for pool sessions, at `/api/v1/socket`.

  The client authenticates with a private (`sk_`) API key passed as the
  Phoenix socket auth token: the endpoint declares the socket with
  `auth_token: true`, so the key travels in the `Sec-WebSocket-Protocol`
  header (`phoenix` plus `base64url.bearer.phx.<token>`, where `<token>` is
  the key in unpadded standard base64) and never in the request line.

  `connect/3` refuses:

    * any `token` query parameter (a key in the URL is never accepted),
    * a missing, unknown, revoked, or expired key, or a public (`pk_`) key,
    * every connection while pools are disabled or the node is draining.

  Connect is not logged (`log: false`). Channels: `pool_session:<id>`
  (`GoodFlowsWeb.SessionChannel`).
  """
  use Phoenix.Socket, log: false

  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Pools.ShutdownDrain

  channel "pool_session:*", GoodFlowsWeb.SessionChannel

  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    with false <- Map.has_key?(params, "token"),
         true <- ShutdownDrain.accepting?(),
         token when is_binary(token) and token != "" <- Map.get(connect_info, :auth_token),
         {:ok, %ApiKey{} = api_key} <- Accounts.verify_api_token(token),
         true <- ApiKey.can_write?(api_key) do
      account = api_key.account_user.account
      {:ok, assign(socket, api_key_id: api_key.id, account_id: account.id)}
    else
      _ -> :error
    end
  end

  @impl Phoenix.Socket
  def id(socket), do: "pool_socket:#{socket.assigns.api_key_id}"
end
