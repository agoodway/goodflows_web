defmodule GoodFlowsWeb.Plugs.CSPNonce do
  @moduledoc """
  Augments the `content-security-policy` header set by
  `put_secure_browser_headers`: adds a per-request nonce to `script-src`,
  and adds the object store's origin to `img-src`, so verify run screenshots
  the evidence download route redirects to can show inline.

  The nonce is assigned as `:csp_nonce` so inline scripts in layouts (the
  theme bootstrapper) and dev tools like LiveDashboard can opt in with
  `nonce={@csp_nonce}`. The policy itself lives in the router so Sobelow can
  verify it; this plug only augments it. Must run after
  `put_secure_browser_headers`.
  """
  @behaviour Plug

  import Plug.Conn

  alias GoodFlows.Caches.ObjectStore

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> augment_policy(nonce, ObjectStore.download_origin())
  end

  defp augment_policy(conn, nonce, store_origin) do
    case get_resp_header(conn, "content-security-policy") do
      [policy | _] ->
        policy =
          policy
          |> String.replace("script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")
          |> then(
            &if(store_origin,
              do: String.replace(&1, "img-src 'self'", "img-src 'self' #{store_origin}"),
              else: &1
            )
          )

        put_resp_header(conn, "content-security-policy", policy)

      [] ->
        conn
    end
  end
end
