defmodule GoodFlowsWeb.ApiKeyLiveTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.Keys
  alias GoodFlows.SpryFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    account_user = account_user_fixture(account, user)

    %{
      account: account,
      account_user: account_user,
      path: ~p"/dashboard/accounts/#{account.id}/api-keys"
    }
  end

  test "shows the empty state", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#api-keys-empty")
  end

  test "creates a key and shows its token once", %{
    conn: conn,
    path: path,
    account_user: account_user
  } do
    {:ok, view, _html} = live(conn, path)

    view |> element("#empty-new-key-btn") |> render_click()
    assert has_element?(view, "#create-key-modal")

    view
    |> form("#create-key-form", api_key: %{name: "Worker", type: "private"})
    |> render_submit()

    assert [api_key] = Accounts.list_api_keys(account_user)
    assert has_element?(view, "#api_keys-#{api_key.id}", "Worker")

    token = view |> element("#token-value") |> render() |> attribute_value("value")
    assert {:ok, %{id: id}} = Accounts.verify_api_token(token)
    assert id == api_key.id

    view |> element("#dismiss-token-btn") |> render_click()
    refute has_element?(view, "#token-display-modal")
  end

  test "shows validation errors", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)
    view |> element("#empty-new-key-btn") |> render_click()

    html = view |> form("#create-key-form", api_key: %{name: ""}) |> render_submit()
    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "#create-key-modal")
  end

  test "revokes a key after confirmation", %{conn: conn, path: path, account_user: account_user} do
    {api_key, token} = api_key_fixture(account_user)
    {:ok, view, _html} = live(conn, path)

    view |> element("#revoke-#{api_key.id}") |> render_click()
    view |> element("#confirm-revoke-btn") |> render_click()

    assert {:error, :invalid_token} = Accounts.verify_api_token(token)
    refute has_element?(view, "#revoke-#{api_key.id}")
    assert has_element?(view, "#api_keys-#{api_key.id}", "Revoked")
  end

  test "cannot revoke another member's key", %{conn: conn, path: path, account: account} do
    other = account_user_fixture(account, user_fixture())
    {api_key, token} = api_key_fixture(other)
    {:ok, view, _html} = live(conn, path)

    render_click(view, "confirm_revoke", %{"id" => api_key.id})
    refute has_element?(view, "#revoke-confirm-modal")
    assert {:ok, _} = Accounts.verify_api_token(token)
  end

  test "minted cache keys are not listed", %{
    conn: conn,
    path: path,
    account: account,
    account_user: account_user
  } do
    project = SpryFixtures.project_fixture(account)

    {:ok, {cache_key, _token}} =
      Keys.mint(account_user, project, %{"access" => "read"})

    {own_key, _token} = api_key_fixture(account_user)

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#api_keys-#{own_key.id}")
    refute has_element?(view, "#api_keys-#{cache_key.id}")
    assert [%{id: id}] = Accounts.list_api_keys(account_user)
    assert id == own_key.id
    refute Accounts.get_api_key(account_user, cache_key.id)
  end

  defp attribute_value(html, attr) do
    html |> LazyHTML.from_fragment() |> LazyHTML.attribute(attr) |> List.first()
  end
end
