defmodule GoodFlowsWeb.Api.V1.MeControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlowsWeb.ApiSpec

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, account} = GoodFlows.Accounts.create_account(user, %{name: "Acme Corp"})
    account_user = GoodFlows.Accounts.get_account_user(user, account)
    {api_key, token} = api_key_fixture(account_user, %{name: "Worker", type: :public})

    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, token: token, api_key: api_key, account: account, user: user}
  end

  test "describes the authenticated key", %{conn: conn, token: token} = ctx do
    body =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/me")
      |> json_response(200)

    assert_schema(body, "MeResponse", ApiSpec.spec())

    assert %{
             "account" => %{"id" => account_id, "slug" => "acme-corp"},
             "user" => %{"email" => email},
             "role" => "owner",
             "api_key" => %{"id" => key_id, "type" => "public"}
           } = body["data"]

    assert account_id == ctx.account.id
    assert email == ctx.user.email
    assert key_id == ctx.api_key.id
  end

  test "rejects requests without a valid key", %{conn: conn} do
    body = conn |> get(~p"/api/v1/me") |> json_response(401)
    assert_schema(body, "ErrorResponse", ApiSpec.spec())

    conn =
      build_conn() |> put_req_header("authorization", "Bearer sk_nope") |> get(~p"/api/v1/me")

    assert json_response(conn, 401)
  end
end
