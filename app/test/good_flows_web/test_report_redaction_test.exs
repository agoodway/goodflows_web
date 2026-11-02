defmodule GoodFlowsWeb.TestReportRedactionTest do
  # Not async: raises the global log level to :debug and collects Sentry events.
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  setup :verify_on_exit!

  import ExUnit.CaptureLog
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures

  @sentinel "SENTINEL-payload-do-not-log-4e7b"

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    Sentry.Test.start_collecting_sentry_reports()
    %{project: project, token: token(ctx.sk_conn)}
  end

  defp token(conn),
    do: conn |> get_req_header("authorization") |> hd() |> String.trim_leading("Bearer ")

  defp upload(conn, slug, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/projects/#{slug}/test-reports", body)
  end

  # A valid report whose first test carries the sentinel in `describe`.
  defp sentinel_report do
    document = report("complete")
    records = records(document)

    started = Enum.find_index(records, &(&1["event"] == "test_started"))
    finished = Enum.find_index(records, &(&1["event"] == "test_finished"))

    document
    |> put_at(["report", "records", started, "describe"], @sentinel)
    |> put_at(["report", "records", finished, "describe"], @sentinel)
  end

  defp refute_leaks(text, ctx) do
    refute text =~ @sentinel
    refute text =~ ctx.token
  end

  defp sentry_probe do
    context = inspect(Sentry.Context.get_all())
    {:ok, _} = Sentry.capture_message("test report probe", result: :sync)
    events = inspect(Sentry.Test.pop_sentry_reports())
    {context, events}
  end

  test "stored, duplicate and conflicting uploads keep the payload out of logs and Sentry", ctx do
    body = Jason.encode!(sentinel_report())

    log =
      capture_log([level: :debug], fn ->
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(200)

        changed = sentinel_report() |> Map.put("job_status", "failed") |> Jason.encode!()
        ctx.sk_conn |> upload(ctx.project.slug, changed) |> json_response(409)
      end)

    # The request itself is logged; its body is not.
    assert log =~ "POST /api/v1/projects/#{ctx.project.slug}/test-reports"
    refute_leaks(log, ctx)

    {context, events} = sentry_probe()
    assert events =~ "test report probe"
    refute_leaks(context, ctx)
    refute_leaks(events, ctx)
  end

  test "validation, parser and storage errors do not reveal submitted values", ctx do
    invalid =
      sentinel_report() |> put_at(["report", "records", 0, "seed"], @sentinel) |> Jason.encode!()

    unknown = sentinel_report() |> Map.put("message", @sentinel) |> Jason.encode!()
    malformed = ~s({"job": "#{@sentinel}")

    log =
      capture_log([level: :debug], fn ->
        for body <- [invalid, unknown] do
          response = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(422)
          refute_leaks(inspect(response), ctx)
        end

        response = ctx.sk_conn |> upload(ctx.project.slug, malformed) |> json_response(400)
        refute_leaks(inspect(response), ctx)

        expect(GoodFlows.TestReports.Store, :insert_all, fn _schema, _rows, _opts ->
          raise DBConnection.ConnectionError, "connection refused"
        end)

        response =
          ctx.sk_conn
          |> upload(ctx.project.slug, Jason.encode!(sentinel_report()))
          |> json_response(503)

        refute_leaks(inspect(response), ctx)
      end)

    refute_leaks(log, ctx)

    {context, events} = sentry_probe()
    refute_leaks(context, ctx)
    refute_leaks(events, ctx)
  end

  test "the Sentry body scrubber drops only the test report route" do
    upload_conn = Phoenix.ConnTest.build_conn(:post, "/api/v1/projects/goodcases/test-reports")
    assert GoodFlowsWeb.SentryScrubber.scrub(upload_conn) == %{}

    other =
      Phoenix.ConnTest.build_conn(:post, "/api/v1/projects")
      |> Map.put(:params, %{"slug" => "x", "password" => "p"})

    assert GoodFlowsWeb.SentryScrubber.scrub(other) == %{"slug" => "x", "password" => "*********"}
  end

  test "upload bodies never become params, so no parameter filter is needed", ctx do
    {conn, log} =
      with_log([level: :debug], fn ->
        upload(ctx.sk_conn, ctx.project.slug, Jason.encode!(sentinel_report()))
      end)

    assert json_response(conn, 201)
    assert log =~ ~s(Parameters: %{"project" => "#{ctx.project.slug}"})
    refute_leaks(log, ctx)

    assert %Plug.Conn.Unfetched{} = conn.body_params
    assert conn.params == %{"project" => ctx.project.slug}
    refute inspect(conn.params) =~ @sentinel

    # "report" is not filtered, so unrelated params such as report_id keep
    # their values in logs.
    assert Phoenix.Logger.filter_values(%{"report_id" => "r-1"}) == %{"report_id" => "r-1"}
  end
end
