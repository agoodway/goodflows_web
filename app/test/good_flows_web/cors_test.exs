defmodule GoodFlowsWeb.CORSTest do
  # Mutates application env, so not async.
  use GoodFlowsWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:good_flows, :cors_origins)
    on_exit(fn -> Application.put_env(:good_flows, :cors_origins, original) end)
  end

  defp preflight(origin) do
    build_conn()
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "GET")
    |> options(~p"/api/v1/me")
  end

  test "reads allowed origins at request time" do
    Application.put_env(:good_flows, :cors_origins, ["https://app.example.com"])
    conn = preflight("https://app.example.com")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.com"]
    assert [allowed_headers] = get_resp_header(conn, "access-control-allow-headers")
    assert allowed_headers =~ "Authorization"

    Application.put_env(:good_flows, :cors_origins, [])
    conn = preflight("https://app.example.com")
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
