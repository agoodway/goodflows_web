defmodule GoodFlowsWeb.Plugs.BodyParsersTest do
  use ExUnit.Case, async: true

  alias GoodFlowsWeb.Plugs.BodyParsers

  @parsers [
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  ]

  setup do
    %{opts: BodyParsers.init(@parsers)}
  end

  test "POST workflow-runs is raw, and the path list is not", %{opts: opts} do
    path = "/api/v1/projects/demo/workflow-runs"
    body = ~s({"workflow":"ci"})

    conn =
      :post
      |> Phoenix.ConnTest.build_conn(path, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> BodyParsers.call(opts)

    assert BodyParsers.raw_body_route?(conn)
    refute BodyParsers.raw_body_route?(conn.path_info)
    assert conn.body_params == %Plug.Conn.Unfetched{aspect: :body_params}
    assert {:ok, ^body, _conn} = Plug.Conn.read_body(conn)
  end

  test "GET workflow-runs still parses query params", %{opts: opts} do
    conn =
      :get
      |> Phoenix.ConnTest.build_conn(
        "/api/v1/projects/demo/workflow-runs?limit=2&workflow=ci&color=blue",
        nil
      )
      |> BodyParsers.call(opts)

    refute BodyParsers.raw_body_route?(conn)
    refute BodyParsers.raw_body_route?(~w(api v1 projects demo workflow-runs))
    assert conn.query_params == %{"limit" => "2", "workflow" => "ci", "color" => "blue"}
  end

  test "test-report uploads stay raw on the path, and other routes are parsed", %{opts: opts} do
    assert BodyParsers.raw_body_route?(~w(api v1 projects demo test-reports))
    assert BodyParsers.test_report_upload?(~w(api v1 projects demo test-reports))

    get_reports =
      :get
      |> Phoenix.ConnTest.build_conn("/api/v1/projects/demo/test-reports?limit=1", nil)
      |> BodyParsers.call(opts)

    assert BodyParsers.raw_body_route?(get_reports)
    assert get_reports.query_params == %Plug.Conn.Unfetched{aspect: :query_params}

    recipe =
      :post
      |> Phoenix.ConnTest.build_conn("/api/v1/projects/demo/recipes", ~s({"name":"app"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> BodyParsers.call(opts)

    refute recipe.halted
    assert recipe.body_params == %{"name" => "app"}
  end
end
