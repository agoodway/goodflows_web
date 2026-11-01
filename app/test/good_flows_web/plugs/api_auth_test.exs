defmodule GoodFlowsWeb.Plugs.ApiAuthTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures

  alias GoodFlowsWeb.Plugs.ApiAuth

  setup do
    account = account_fixture()
    account_user = account_user_fixture(account, user_fixture())
    %{account: account, account_user: account_user}
  end

  defp authenticate(conn, token, opts \\ []) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> ApiAuth.call(ApiAuth.init(opts))
  end

  test "assigns the key, membership, account, and scope", %{
    conn: conn,
    account: account,
    account_user: account_user
  } do
    {api_key, token} = api_key_fixture(account_user)
    conn = authenticate(conn, token)

    refute conn.halted
    assert conn.assigns.current_api_key.id == api_key.id
    assert conn.assigns.current_account.id == account.id
    assert conn.assigns.current_account_user.id == account_user.id
    assert conn.assigns.current_scope.user.id == account_user.user_id
    assert conn.assigns.current_api_key.last_used_at
  end

  test "rejects missing and invalid tokens with 401", %{conn: conn} do
    conn = ApiAuth.call(conn, ApiAuth.init([]))
    assert conn.halted
    assert %{"errors" => %{"detail" => "Unauthorized" <> _}} = json_response(conn, 401)
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    conn = authenticate(build_conn(), "sk_bogus")
    assert conn.halted
    assert conn.status == 401
  end

  test "require_write_access allows private keys only", %{account_user: account_user} do
    {_api_key, public} = api_key_fixture(account_user, %{type: :public})
    {_api_key, private} = api_key_fixture(account_user, %{type: :private})

    conn = build_conn() |> authenticate(public) |> ApiAuth.call(:require_write_access)
    assert conn.halted
    assert %{"errors" => %{"detail" => "Forbidden" <> _}} = json_response(conn, 403)

    conn = build_conn() |> authenticate(private) |> ApiAuth.call(:require_write_access)
    refute conn.halted
  end
end
