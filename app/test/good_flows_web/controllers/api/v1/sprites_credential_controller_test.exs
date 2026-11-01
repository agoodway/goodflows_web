defmodule GoodFlowsWeb.Api.V1.SpritesCredentialControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias GoodFlows.Spry
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  @token "sprites_live_secret_a1b2"

  test "reports not configured", %{pk_conn: conn} do
    body = conn |> get(~p"/api/v1/sprites-credential") |> json_response(200)
    assert_schema(body, "SpritesCredentialStatus", ApiSpec.spec())
    assert body["data"]["configured"] == false
  end

  test "set, read, replace, and remove without ever returning the token", ctx do
    put_conn = ctx.sk_conn |> put(~p"/api/v1/sprites-credential", %{"token" => @token})
    body = json_response(put_conn, 200)
    refute put_conn.resp_body =~ @token
    assert body["data"]["configured"] == true

    get_conn = ctx.pk_conn |> get(~p"/api/v1/sprites-credential")
    body = json_response(get_conn, 200)
    refute get_conn.resp_body =~ @token
    assert_schema(body, "SpritesCredentialStatus", ApiSpec.spec())
    assert %{"configured" => true, "last4" => "a1b2", "updated_at" => updated_at} = body["data"]
    assert is_binary(updated_at)
    refute Map.has_key?(body["data"], "token")

    ctx.sk_conn
    |> put(~p"/api/v1/sprites-credential", %{"token" => "other-9999"})
    |> json_response(200)

    assert Spry.fetch_token(ctx.account.id) == {:ok, "other-9999"}

    assert ctx.sk_conn |> delete(~p"/api/v1/sprites-credential") |> response(204)
    assert ctx.sk_conn |> delete(~p"/api/v1/sprites-credential") |> response(204)

    body = ctx.pk_conn |> get(~p"/api/v1/sprites-credential") |> json_response(200)
    assert body["data"]["configured"] == false
  end

  test "blank or missing token is 422", %{sk_conn: conn} do
    body = conn |> put(~p"/api/v1/sprites-credential", %{"token" => " "}) |> json_response(422)
    assert body["errors"]["token"]
    body = conn |> put(~p"/api/v1/sprites-credential", %{}) |> json_response(422)
    assert body["errors"]["token"]
  end

  test "short tokens report last4 null", %{sk_conn: conn} do
    body = conn |> put(~p"/api/v1/sprites-credential", %{"token" => "abcd"}) |> json_response(200)
    assert body["data"]["last4"] == nil
    refute body |> Jason.encode!() =~ "abcd"
  end

  test "public keys cannot set or remove", ctx do
    {:ok, _} = Spry.put_credential(ctx.account, %{"token" => @token})

    assert ctx.pk_conn
           |> put(~p"/api/v1/sprites-credential", %{"token" => "x-1234"})
           |> json_response(403)

    assert ctx.pk_conn |> delete(~p"/api/v1/sprites-credential") |> json_response(403)
    assert Spry.fetch_token(ctx.account.id) == {:ok, @token}
  end

  test "members who are not owners or admins cannot set or remove", ctx do
    {:ok, _} = Spry.put_credential(ctx.account, %{"token" => @token})

    body =
      ctx.member_sk_conn
      |> put(~p"/api/v1/sprites-credential", %{"token" => "x-1234"})
      |> json_response(403)

    assert_schema(body, "ErrorResponse", ApiSpec.spec())
    assert ctx.member_sk_conn |> delete(~p"/api/v1/sprites-credential") |> json_response(403)
    assert Spry.fetch_token(ctx.account.id) == {:ok, @token}

    # They can still read the status.
    assert ctx.member_sk_conn |> get(~p"/api/v1/sprites-credential") |> json_response(200)
  end

  test "admins can set and remove", ctx do
    admin = GoodFlows.AccountsFixtures.user_fixture()
    admin_au = GoodFlows.AccountsFixtures.account_user_fixture(ctx.account, admin, :admin)
    {_key, token} = GoodFlows.AccountsFixtures.api_key_fixture(admin_au, %{type: :private})
    conn = api_conn(token)

    assert conn |> put(~p"/api/v1/sprites-credential", %{"token" => @token}) |> json_response(200)
    assert Spry.fetch_token(ctx.account.id) == {:ok, @token}
    assert api_conn(token) |> delete(~p"/api/v1/sprites-credential") |> response(204)
  end

  test "the OpenAPI document lists 403 for credential writes", %{conn: conn} do
    doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    for method <- ["put", "delete"] do
      response = doc["paths"]["/api/v1/sprites-credential"][method]["responses"]["403"]
      assert response["description"] =~ "owner or admin"
    end
  end

  test "credentials are per account", ctx do
    {:ok, _} = Spry.put_credential(ctx.account, %{"token" => @token})
    body = ctx.other_conn |> get(~p"/api/v1/sprites-credential") |> json_response(200)
    assert body["data"]["configured"] == false
  end
end
