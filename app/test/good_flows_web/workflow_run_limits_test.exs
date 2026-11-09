defmodule GoodFlowsWeb.WorkflowRunLimitsTest do
  # Not async: overrides the global read deadline and body-limit config.
  use GoodFlowsWeb.ConnCase, async: false

  import Plug.Conn
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlowsWeb.GreedyBodyAdapter
  alias GoodFlowsWeb.Plugs.WorkflowRunBody

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)

    previous = %{
      bytes: Application.get_env(:good_flows, :workflow_run_max_body_bytes),
      timeout: Application.get_env(:good_flows, :workflow_run_read_timeout_ms)
    }

    on_exit(fn ->
      Application.put_env(:good_flows, :workflow_run_max_body_bytes, previous.bytes)
      Application.put_env(:good_flows, :workflow_run_read_timeout_ms, previous.timeout)
    end)

    %{project: project}
  end

  defp upload(conn, slug, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/projects/#{slug}/workflow-runs", body)
  end

  defp body_unread?(conn, body), do: match?({:ok, ^body, _conn}, Plug.Conn.read_body(conn))

  test "defaults are 4 MiB and 30 seconds when unset" do
    Application.delete_env(:good_flows, :workflow_run_max_body_bytes)
    Application.delete_env(:good_flows, :workflow_run_read_timeout_ms)

    assert WorkflowRunBody.max_body_bytes() == 4_194_304
    assert WorkflowRunBody.read_timeout_ms() == 30_000
  end

  test "a body not fully read within the deadline is 408 and stores nothing", ctx do
    Application.put_env(:good_flows, :workflow_run_read_timeout_ms, 0)
    body = json("minimal")

    conn = upload(ctx.sk_conn, ctx.project.slug, body)

    assert json_response(conn, 408)["errors"]["detail"] =~ "not received in time"
    assert body_unread?(conn, body)
    assert GoodFlows.Repo.aggregate(GoodFlows.WorkflowRuns.Run, :count) == 0
  end

  test "a slow chunked body that passes the deadline is 408" do
    Application.put_env(:good_flows, :workflow_run_read_timeout_ms, 40)

    conn =
      :post
      |> Plug.Test.conn("/api/v1/projects/p/workflow-runs", json("minimal"))
      |> put_req_header("content-type", "application/json")
      |> GreedyBodyAdapter.wrap(trickle: {20, 30})
      |> WorkflowRunBody.call([])

    assert conn.halted
    assert conn.status == 408
  end
end
