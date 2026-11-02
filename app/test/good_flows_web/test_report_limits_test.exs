defmodule GoodFlowsWeb.TestReportLimitsTest do
  # Not async: overrides the global body limit, read deadline and admission
  # caps, which every test report upload reads.
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures

  alias GoodFlows.Repo
  alias GoodFlows.TestReports.{Report, Store}
  alias GoodFlowsWeb.{GreedyBodyAdapter, TestReportAdmission}
  alias GoodFlowsWeb.Plugs.TestReportBody

  setup :verify_on_exit!
  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp put_config(key, value) do
    previous = Application.fetch_env!(:good_flows, key)
    Application.put_env(:good_flows, key, value)
    on_exit(fn -> Application.put_env(:good_flows, key, previous) end)
  end

  defp upload(conn, slug, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/projects/#{slug}/test-reports", body)
  end

  defp plug_conn(body, adapter_opts) do
    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> GreedyBodyAdapter.wrap(adapter_opts)
  end

  defp eventually_in_use(expected, attempts \\ 50) do
    cond do
      TestReportAdmission.in_use() == expected ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually_in_use(expected, attempts - 1)
    end
  end

  # Holds a slot for `account_id` from another process until that process
  # is killed, by the test or at the latest in on_exit.
  defp hold_slot(account_id \\ nil) do
    test = self()

    holder =
      spawn(fn ->
        {:ok, _slot} = TestReportAdmission.acquire(account_id)
        send(test, :holding)
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive :holding
    holder
  end

  defp heap_limit, do: Process.info(self(), :max_heap_size) |> elem(1)

  describe "admission" do
    test "a full cap is 503 with Retry-After before reading; slots return when holders exit",
         ctx do
      put_config(:test_report_max_concurrent_uploads, 1)
      holder = hold_slot()
      body = report_json("complete")

      conn = upload(ctx.sk_conn, ctx.project.slug, body)
      assert json_response(conn, 503)["errors"]["detail"] =~ "retry"
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert {:ok, ^body, _} = Plug.Conn.read_body(conn)
      assert Repo.aggregate(Report, :count) == 0

      Process.exit(holder, :kill)
      assert eventually_in_use(0)
      assert ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
    end

    test "one account cannot take more than its per-account slots", ctx do
      put_config(:test_report_max_concurrent_uploads, 10)
      put_config(:test_report_max_concurrent_uploads_per_account, 1)
      hold_slot(ctx.account.id)
      body = report_json("complete")

      conn = upload(ctx.sk_conn, ctx.project.slug, body)
      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert {:ok, ^body, _} = Plug.Conn.read_body(conn)

      # Another account still gets a slot.
      other_project = project_fixture(ctx.other_account)
      assert ctx.other_conn |> upload(other_project.slug, body) |> json_response(201)
      assert eventually_in_use(1)
    end

    test "slots are released after success and every kind of rejection", ctx do
      put_config(:test_report_max_concurrent_uploads, 1)
      complete = report_json("complete")

      assert ctx.sk_conn |> upload(ctx.project.slug, complete) |> json_response(201)
      assert TestReportAdmission.in_use() == 0

      # Duplicate and conflict.
      assert ctx.sk_conn |> upload(ctx.project.slug, complete) |> json_response(200)
      assert TestReportAdmission.in_use() == 0

      changed = report("complete") |> Map.put("job_status", "failed") |> Jason.encode!()
      assert ctx.sk_conn |> upload(ctx.project.slug, changed) |> json_response(409)
      assert TestReportAdmission.in_use() == 0

      assert ctx.sk_conn |> upload(ctx.project.slug, "{") |> json_response(400)
      assert TestReportAdmission.in_use() == 0

      deep = String.duplicate("[", 40)
      assert ctx.sk_conn |> upload(ctx.project.slug, deep) |> json_response(422)
      assert TestReportAdmission.in_use() == 0

      oversized = String.duplicate(" ", TestReportBody.max_body_bytes() + 1)
      assert ctx.sk_conn |> upload(ctx.project.slug, oversized) |> json_response(413)
      assert TestReportAdmission.in_use() == 0

      invalid = Jason.encode!(Map.put(report("complete"), "project", "x"))
      assert ctx.sk_conn |> upload(ctx.project.slug, invalid) |> json_response(422)
      assert TestReportAdmission.in_use() == 0

      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise DBConnection.ConnectionError, "closed"
      end)

      assert ctx.sk_conn |> upload(ctx.project.slug, report_json("failed")) |> json_response(503)
      assert TestReportAdmission.in_use() == 0

      # Every admitted request finished, so the single slot is still usable.
      assert ctx.sk_conn |> upload(ctx.project.slug, report_json("failed")) |> json_response(201)
    end

    test "the slot and heap limit are held through validation and persistence", ctx do
      put_config(:test_report_max_concurrent_uploads, 1)
      previous_heap = heap_limit()
      words = div(TestReportBody.max_heap_bytes(), :erlang.system_info(:wordsize))

      expect(Store, :insert_all, fn schema, rows, opts ->
        assert TestReportAdmission.in_use() == 1
        assert TestReportAdmission.acquire(ctx.other_account.id) == :full
        assert heap_limit().size == words
        call_original(Store, :insert_all, [schema, rows, opts])
      end)

      assert ctx.sk_conn
             |> upload(ctx.project.slug, report_json("complete"))
             |> json_response(201)

      assert TestReportAdmission.in_use() == 0
      assert heap_limit() == previous_heap
    end

    test "an unexpected storage error is a 500 and still releases the slot", ctx do
      put_config(:test_report_max_concurrent_uploads, 1)
      previous_heap = heap_limit()

      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise %Postgrex.Error{postgres: %{code: nil, pg_code: "XX000", message: "internal"}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert_error_sent 500, fn ->
            upload(ctx.sk_conn, ctx.project.slug, report_json("complete"))
          end
        end)

      assert log =~ "SQLSTATE XX000"

      assert TestReportAdmission.in_use() == 0
      assert heap_limit() == previous_heap
    end

    test "a request process killed while reading releases its slot" do
      put_config(:test_report_max_concurrent_uploads, 1)
      test = self()

      request =
        spawn(fn -> "{}" |> plug_conn(block: test) |> TestReportBody.call([]) end)

      assert_receive {:reading_body, ^request}
      assert TestReportAdmission.in_use() == 1
      assert TestReportAdmission.acquire(nil) == :full

      Process.exit(request, :kill)
      assert eventually_in_use(0)
    end

    test "an unreachable admission server means :full, not a crash" do
      :sys.suspend(TestReportAdmission)
      on_exit(fn -> :sys.resume(TestReportAdmission) end)

      assert TestReportAdmission.acquire(nil) == :full

      :sys.resume(TestReportAdmission)
      # The request that timed out was not granted a slot afterwards.
      assert TestReportAdmission.in_use() == 0
    end
  end

  describe "reading" do
    test "a body still arriving at the read deadline is 408 and releases the slot" do
      put_config(:test_report_read_timeout_ms, 50)
      previous_heap = heap_limit()

      conn =
        report_json("complete")
        |> plug_conn(trickle: {100, 20})
        |> TestReportBody.call([])

      assert conn.halted
      assert conn.status == 408
      assert Jason.decode!(conn.resp_body)["errors"]["detail"] =~ "not received in time"
      assert TestReportAdmission.in_use() == 0
      assert heap_limit() == previous_heap
    end

    test "a slow body inside the deadline is read in pieces" do
      conn =
        report_json("complete")
        |> plug_conn(trickle: {4_000, 1})
        |> TestReportBody.call([])

      refute conn.halted
      assert conn.assigns.test_report_document

      conn = TestReportBody.finish(conn)
      assert TestReportAdmission.in_use() == 0
      refute Map.has_key?(conn.private, :test_report_admission)
    end

    test "an unreadable body is 400 and releases the slot" do
      conn = "{}" |> plug_conn(error: :closed) |> TestReportBody.call([])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["errors"]["detail"] =~ "could not be read"
      assert TestReportAdmission.in_use() == 0
    end
  end

  @tag :slow
  test "the real 32 MiB limit accepts exactly 33,554,432 bytes and rejects one more", ctx do
    put_config(:test_report_max_body_bytes, 33_554_432)
    assert TestReportBody.max_body_bytes() == 32 * 1024 * 1024

    json = report_json("complete")
    padded = json <> String.duplicate(" ", 33_554_432 - byte_size(json))

    assert ctx.sk_conn |> upload(ctx.project.slug, padded) |> json_response(201)
    assert ctx.sk_conn |> upload(ctx.project.slug, padded <> " ") |> json_response(413)
  end

  @tag :slow
  @tag timeout: 300_000
  test "a 100,000-record report just under 32 MiB is stored end to end", ctx do
    put_config(:test_report_max_body_bytes, 33_554_432)

    # Built in another process so its terms do not count towards the
    # request's heap limit (this test process is the request process).
    json =
      fn -> 100_000 |> large_report(33_554_432) |> Jason.encode!() end
      |> Task.async()
      |> Task.await(120_000)

    assert byte_size(json) <= 33_554_432
    assert byte_size(json) > 33_000_000

    body = ctx.sk_conn |> upload(ctx.project.slug, json) |> json_response(201)
    assert %{"status" => "complete", "duplicate" => false, "id" => id} = body["data"]

    assert Repo.one(
             from r in Report,
               where: r.id == ^id,
               select: fragment("jsonb_array_length(? -> 'report' -> 'records')", r.payload)
           ) == 100_000

    assert TestReportAdmission.in_use() == 0
  end
end
