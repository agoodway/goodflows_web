defmodule GoodFlowsWeb.DashboardLiveTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture(%{name: "Acme Corp"})
    account_user_fixture(account, user, :owner)
    %{account: account}
  end

  describe "GET /dashboard" do
    test "redirects to the user's account", %{conn: conn, account: account} do
      conn = get(conn, ~p"/dashboard")
      assert redirected_to(conn) == ~p"/dashboard/accounts/#{account.id}"
    end

    test "remembers the last visited account", %{conn: conn, user: user} do
      other = account_fixture(%{name: "Zulu Co"})
      account_user_fixture(other, user)

      conn = get(conn, ~p"/dashboard/accounts/#{other.id}")
      conn = conn |> recycle() |> get(~p"/dashboard")

      assert redirected_to(conn) == ~p"/dashboard/accounts/#{other.id}"
    end

    test "sends users without accounts home with a flash" do
      conn = build_conn() |> log_in_user(user_fixture()) |> get(~p"/dashboard")
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "any accounts"
    end
  end

  describe "account dashboard" do
    test "renders the dashboard shell", %{conn: conn, account: account} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/accounts/#{account.id}")

      assert has_element?(view, "#dashboard h1", "Acme Corp")
      assert has_element?(view, "nav[aria-label=Breadcrumb]", "Dashboard")
      assert has_element?(view, "#account-switcher")
    end

    test "redirects away from accounts the user does not belong to", %{conn: conn} do
      foreign = account_fixture()

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/dashboard/accounts/#{foreign.id}")
    end

    test "requires authentication", %{account: account} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/dashboard/accounts/#{account.id}")
    end
  end
end
