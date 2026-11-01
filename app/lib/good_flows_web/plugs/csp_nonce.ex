defmodule GoodFlowsWeb.Plugs.CSPNonce do
  @moduledoc """
  Adds a per-request nonce to the `script-src` directive of the
  `content-security-policy` header set by `put_secure_browser_headers`.

  The nonce is assigned as `:csp_nonce` so inline scripts in layouts (the
  theme bootstrapper) and dev tools like LiveDashboard can opt in with
  `nonce={@csp_nonce}`. The policy itself lives in the router so Sobelow can
  verify it; this plug only augments it. Must run after
  `put_secure_browser_headers`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> add_nonce_to_policy(nonce)
  end

  defp add_nonce_to_policy(conn, nonce) do
    case get_resp_header(conn, "content-security-policy") do
      [policy | _] ->
        policy = String.replace(policy, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")
        put_resp_header(conn, "content-security-policy", policy)

      [] ->
        conn
    end
  end
end
