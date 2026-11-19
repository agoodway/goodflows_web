defmodule GoodFlowsWeb.UserLive.RegistrationToggleTest do
  # Not async: these tests change application env read by other views.
  use GoodFlowsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp set_registration_enabled(enabled) do
    previous = Application.fetch_env(:good_flows, :user_registration_enabled)
    Application.put_env(:good_flows, :user_registration_enabled, enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:good_flows, :user_registration_enabled, value)
        :error -> Application.delete_env(:good_flows, :user_registration_enabled)
      end
    end)
  end

  describe "registration enabled" do
    setup do: set_registration_enabled(true)

    test "renders the registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Register for an account"
    end

    test "shows sign up links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ "Sign up"
      assert html =~ ~s(href="/users/register")

      assert html_response(get(conn, ~p"/"), 200) =~ "home-register-link"
    end
  end

  describe "registration disabled" do
    setup do: set_registration_enabled(false)

    test "redirects to the login page with a flash", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
               live(conn, ~p"/users/register")

      assert flash["error"] =~ "unavailable"
    end

    test "hides sign up links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      refute html =~ "Sign up"
      refute html =~ ~s(href="/users/register")

      refute html_response(get(conn, ~p"/"), 200) =~ "/users/register"
    end
  end
end
