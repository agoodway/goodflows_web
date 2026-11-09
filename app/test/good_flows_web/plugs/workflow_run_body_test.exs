defmodule GoodFlowsWeb.Plugs.WorkflowRunBodyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlows.JsonDocument
  alias GoodFlowsWeb.GreedyBodyAdapter
  alias GoodFlowsWeb.Plugs.WorkflowRunBody

  defp conn_with(body, headers \\ [{"content-type", "application/json"}]) do
    Enum.reduce(headers, conn(:post, "/api/v1/projects/p/workflow-runs", body), fn {key, value},
                                                                                   conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp detail(conn), do: conn.resp_body |> Jason.decode!() |> get_in(["errors", "detail"])

  defp errors(conn), do: conn.resp_body |> Jason.decode!() |> Map.fetch!("errors")

  test "assigns the normalized document" do
    conn = json("minimal") |> conn_with() |> WorkflowRunBody.call([])

    refute conn.halted
    assert conn.private.workflow_run_document == minimal()
  end

  test "charset=utf-8 is accepted" do
    conn =
      json("minimal")
      |> conn_with([{"content-type", "application/json; charset=UTF-8"}])
      |> WorkflowRunBody.call([])

    refute conn.halted
  end

  test "a declared Content-Length over the limit is 413 without reading" do
    body = json("minimal")
    limit = WorkflowRunBody.max_body_bytes()

    conn =
      body
      |> conn_with()
      |> put_req_header("content-length", Integer.to_string(limit + 1))
      |> WorkflowRunBody.call([])

    assert conn.halted
    assert conn.status == 413
    assert detail(conn) =~ "size limit"
    assert {:ok, ^body, _} = read_body(conn)
  end

  test "an adapter returning {:ok, body, conn} above the limit is 413" do
    body = String.duplicate(" ", WorkflowRunBody.max_body_bytes() + 1)
    conn = body |> conn_with() |> GreedyBodyAdapter.wrap() |> WorkflowRunBody.call([])

    assert conn.halted
    assert conn.status == 413
    assert detail(conn) =~ "size limit"
  end

  test "a body exactly at the limit is accepted" do
    json = json("minimal")
    limit = WorkflowRunBody.max_body_bytes()
    body = json <> String.duplicate(" ", limit - byte_size(json))
    assert byte_size(body) == limit

    conn = body |> conn_with() |> GreedyBodyAdapter.wrap() |> WorkflowRunBody.call([])
    refute conn.halted
    assert conn.private.workflow_run_document["workflow"] == "ci"

    over = body <> " "
    conn = over |> conn_with() |> GreedyBodyAdapter.wrap() |> WorkflowRunBody.call([])
    assert conn.status == 413
  end

  test "a missing or repeated Content-Type is 415" do
    conn = conn(:post, "/", json("minimal")) |> WorkflowRunBody.call([])
    assert conn.status == 415

    conn =
      json("minimal")
      |> conn_with([{"content-type", "application/json"}])
      |> Map.update!(:req_headers, &[{"content-type", "application/json"} | &1])
      |> WorkflowRunBody.call([])

    assert conn.status == 415
  end

  test "a non-JSON content type or a non-identity encoding is 415 without reading" do
    body = json("minimal")

    for type <- ["text/plain", "application/json; charset=latin1"] do
      conn = body |> conn_with([{"content-type", type}]) |> WorkflowRunBody.call([])
      assert conn.status == 415
      assert {:ok, ^body, _} = read_body(conn)
    end

    conn =
      body
      |> conn_with([
        {"content-type", "application/json"},
        {"content-encoding", "gzip"}
      ])
      |> WorkflowRunBody.call([])

    assert conn.status == 415
    assert detail(conn) =~ "Content-Encoding"
    assert {:ok, ^body, _} = read_body(conn)
  end

  test "malformed JSON is 400 and does not echo the body" do
    sentinel = "SENTINEL-plug-malformed-9c2a"
    conn = ~s({"workflow":"#{sentinel}") |> conn_with() |> WorkflowRunBody.call([])

    assert conn.status == 400
    assert detail(conn) =~ "not valid JSON"
    refute conn.resp_body =~ sentinel
  end

  test "nesting deeper than 8 is 422 on body; depth 8 reaches the decoder" do
    nested = fn depth -> String.duplicate("[", depth) <> String.duplicate("]", depth) end

    assert JsonDocument.check_depth(nested.(8), 8) == :ok
    assert JsonDocument.check_depth(nested.(9), 8) == {:error, :too_deep}

    conn = nested.(9) |> conn_with() |> WorkflowRunBody.call([])
    assert conn.halted
    assert conn.status == 422
    assert errors(conn) == %{"body" => ["is nested too deeply"]}

    conn = nested.(8) |> conn_with() |> WorkflowRunBody.call([])
    refute conn.halted
  end

  test "duplicate keys, NUL and integers above 2^53-1 are 422 from normalize" do
    duplicate = ~s({"outcome":"passed","outcome":"failed"})
    conn = duplicate |> conn_with() |> WorkflowRunBody.call([])
    assert conn.status == 422
    assert errors(conn) == %{"body" => ["has a duplicate key"]}

    nul = ~s({"workflow":"ci\\u0000"})
    conn = nul |> conn_with() |> WorkflowRunBody.call([])
    assert conn.status == 422
    assert errors(conn)["workflow"] == ["must not contain NUL characters"]

    huge = "9007199254740992"
    body = ~s({"duration_ms":#{huge},"secret_token_xyz":#{huge}})
    conn = body |> conn_with() |> WorkflowRunBody.call([])
    assert conn.status == 422
    assert errors(conn)["duration_ms"] == ["is out of range"]
    refute conn.resp_body =~ "secret_token_xyz"
    refute conn.resp_body =~ huge
  end

  test "an unreadable body is 400" do
    conn =
      "{}" |> conn_with() |> GreedyBodyAdapter.wrap(error: :closed) |> WorkflowRunBody.call([])

    assert conn.status == 400
    assert detail(conn) =~ "could not be read"
  end
end
