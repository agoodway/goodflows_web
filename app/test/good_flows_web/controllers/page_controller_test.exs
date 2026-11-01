defmodule GoodFlowsWeb.PageControllerTest do
  use GoodFlowsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ ~s(id="home-hero")
    assert html =~ ~s(id="home-login-link")
  end
end
