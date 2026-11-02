defmodule GoodFlowsWeb.Plugs.TestReportBodyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  import GoodFlows.TestReportFixtures

  alias GoodFlows.TestReports.{Document, Validator}
  alias GoodFlowsWeb.GreedyBodyAdapter
  alias GoodFlowsWeb.Plugs.TestReportBody

  defp conn_with(body, headers \\ [{"content-type", "application/json"}]) do
    Enum.reduce(headers, conn(:post, "/api/v1/projects/p/test-reports", body), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
  end

  defp detail(conn), do: conn.resp_body |> Jason.decode!() |> get_in(["errors", "detail"])

  test "assigns the decoded document" do
    conn = TestReportBody.call(conn_with(report_json("complete")), [])

    refute conn.halted

    assert {:ok, document, "complete"} =
             Validator.validate(conn.assigns.test_report_document)

    assert document == report("complete")
  end

  test "an adapter returning {:ok, body, conn} above the limit is 413" do
    body = String.duplicate(" ", TestReportBody.max_body_bytes() + 1)
    conn = body |> conn_with() |> GreedyBodyAdapter.wrap() |> TestReportBody.call([])

    assert conn.halted
    assert conn.status == 413
    assert detail(conn) =~ "size limit"
  end

  test "an adapter returning the whole body at the limit is accepted" do
    json = report_json("complete")
    body = json <> String.duplicate(" ", TestReportBody.max_body_bytes() - byte_size(json))
    conn = body |> conn_with() |> GreedyBodyAdapter.wrap() |> TestReportBody.call([])

    refute conn.halted
  end

  test "a missing or repeated Content-Type is 415" do
    conn = conn(:post, "/", report_json("complete")) |> TestReportBody.call([])
    assert conn.status == 415

    conn =
      report_json("complete")
      |> conn_with([{"content-type", "application/json"}])
      |> Map.update!(:req_headers, &[{"content-type", "application/json"} | &1])
      |> TestReportBody.call([])

    assert conn.status == 415
  end

  test "error bodies are fixed JSON without request data" do
    sentinel = "SENTINEL-plug-3b9d"

    conn =
      conn_with(~s({"#{sentinel}": ), [{"content-type", "application/json"}])
      |> TestReportBody.call([])

    assert conn.status == 400
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    refute conn.resp_body =~ sentinel
  end

  describe "nesting depth" do
    defp nested(depth), do: String.duplicate("[", depth) <> String.duplicate("]", depth)

    test "the cap leaves room for the deepest contract structure" do
      # body → report → records → suite_finished → files → file → bucket → counts
      assert Document.max_depth() == 16
      assert Document.check_depth(report_json("complete")) == :ok
    end

    test "a body at the cap reaches the decoder; one level deeper is 422 on body" do
      assert Document.check_depth(nested(16)) == :ok
      assert Document.check_depth(nested(17)) == {:error, :too_deep}

      conn = nested(17) |> conn_with() |> TestReportBody.call([])
      assert conn.halted
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body) == %{"errors" => %{"body" => ["is nested too deeply"]}}

      # At the cap the body is decoded; an array body then fails validation.
      conn = nested(16) |> conn_with() |> TestReportBody.call([])
      refute conn.halted
    end

    test "brackets inside strings, including after escaped quotes, do not count" do
      inside = ~s({"a": "#{String.duplicate("[{", 40)} \\" #{String.duplicate("[", 40)}"})
      assert Document.check_depth(inside) == :ok
      assert {:ok, _} = Document.decode(inside)

      escaped_backslash = ~s(["\\\\", #{nested(16)}])
      assert Document.check_depth(escaped_backslash) == {:error, :too_deep}
    end

    test "a deep but unterminated body is rejected by the scan" do
      conn = String.duplicate("{\"a\":", 100) |> conn_with() |> TestReportBody.call([])
      assert conn.status == 422
    end
  end

  test "finish/1 is safe to repeat and on a conn without a slot" do
    conn = report_json("complete") |> conn_with() |> TestReportBody.call([])
    assert %{test_report_admission: _} = conn.private

    conn = conn |> TestReportBody.finish() |> TestReportBody.finish()
    refute Map.has_key?(conn.private, :test_report_admission)
    bare = conn_with("{}")
    assert TestReportBody.finish(bare) == bare
  end
end
