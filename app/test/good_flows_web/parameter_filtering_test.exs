defmodule GoodFlowsWeb.ParameterFilteringTest do
  # Not async: raises the global log level to :debug to see request params.
  use GoodFlowsWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup :api_setup

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  @token "sprites_live_do_not_log_7c3d"

  test "the Sprites token is filtered from request logs", %{sk_conn: conn} do
    log =
      capture_log([level: :debug], fn ->
        conn |> put(~p"/api/v1/sprites-credential", %{"token" => @token}) |> json_response(200)
      end)

    assert log =~ "Parameters: %{\"token\" => \""
    refute log =~ @token
  end

  test "Phoenix filters any parameter containing token or password" do
    assert Phoenix.Logger.filter_values(%{"token" => @token, "password" => "p", "name" => "n"}) ==
             %{"token" => "[FILTERED]", "password" => "[FILTERED]", "name" => "n"}
  end
end
