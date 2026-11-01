defmodule GoodFlowsWeb.Plugs.CSPNonceTest do
  use GoodFlowsWeb.ConnCase, async: true

  test "browser responses carry a nonce that matches the inline theme script", %{conn: conn} do
    conn = get(conn, ~p"/")

    [policy] = get_resp_header(conn, "content-security-policy")
    nonce = conn.assigns.csp_nonce

    assert policy =~ "script-src 'self' 'nonce-#{nonce}'"
    assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
  end
end
