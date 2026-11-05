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

  # A valid report whose first test carries the sentinel in its `name` and
  # in a string `meta` value, on both events of the pair.
  defp sentinel_report do
    document = report("complete")
    records = records(document)

    started = Enum.find_index(records, &(&1["event"] == "test_started"))
    finished = Enum.find_index(records, &(&1["event"] == "test_finished"))

    Enum.reduce([started, finished], document, fn index, document ->
      document
      |> put_at(["report", "records", index, "name"], @sentinel)
      |> put_at(["report", "records", index, "meta"], %{"note" => @sentinel})
    end)
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

  test "an invalid meta key is a 422 on that record's meta without echoing the key", ctx do
    started = report("complete") |> records() |> Enum.find_index(&(&1["event"] == "test_started"))

    body =
      sentinel_report()
      |> put_at(["report", "records", started, "meta"], %{"stack trace" => @sentinel})
      |> Jason.encode!()

    log =
      capture_log([level: :debug], fn ->
        response = ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(422)

        assert response == %{
                 "errors" => %{"report.records[#{started}].meta" => ["has an invalid key"]}
               }

        refute inspect(response) =~ "stack trace"
        refute_leaks(inspect(response), ctx)
      end)

    refute log =~ "stack trace"
    refute_leaks(log, ctx)
  end

  test "a bad meta value is a 422 on that record's meta without echoing its key", ctx do
    started = report("complete") |> records() |> Enum.find_index(&(&1["event"] == "test_started"))

    for token <- ["99999999999999999999", "-99999999999999999999", ~s("x\\u0000")] do
      body =
        sentinel_report()
        |> put_at(["report", "records", started, "meta"], %{"db_password" => 900_000_007})
        |> Jason.encode!()
        |> String.replace("900000007", token)

      log =
        capture_log([level: :debug], fn ->
          conn = ctx.sk_conn |> upload(ctx.project.slug, body)

          assert json_response(conn, 422) == %{
                   "errors" => %{"report.records[#{started}].meta" => ["has an invalid value"]}
                 }

          refute conn.resp_body =~ "db_password"
          refute_leaks(conn.resp_body, ctx)
        end)

      refute log =~ "db_password"
      refute_leaks(log, ctx)
    end
  end

  test "an unknown key with a bad value is reported without its name", ctx do
    body =
      sentinel_report()
      |> put_at(["source", "db_password"], 900_000_007)
      |> Jason.encode!()
      |> String.replace("900000007", "99999999999999999999")

    log =
      capture_log([level: :debug], fn ->
        conn = ctx.sk_conn |> upload(ctx.project.slug, body)
        assert json_response(conn, 422) == %{"errors" => %{"source" => ["is out of range"]}}
        refute conn.resp_body =~ "db_password"
      end)

    refute log =~ "db_password"
    refute_leaks(log, ctx)
  end

  test "a format rejection logs one sanitized line without payload values", ctx do
    user_agent = "goodflows/0.5.2 (linux)\n\e[31mforged line " <> String.duplicate("u", 300)

    retired =
      sentinel_report()
      |> Map.put("format", "exunit-timings")
      |> Map.put(@sentinel, @sentinel)
      |> Jason.encode!()

    other = sentinel_report() |> Map.put("format", @sentinel) |> Jason.encode!()

    record =
      sentinel_report()
      |> put_at(["report", "records", 0, "format"], @sentinel)
      |> Jason.encode!()

    send = fn body ->
      ctx.sk_conn
      |> put_req_header("user-agent", user_agent)
      |> upload(ctx.project.slug, body)
      |> json_response(422)
    end

    log = capture_log([level: :info], fn -> send.(retired) end)
    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "Test reports: rejected"))
    assert [line] = lines
    assert line =~ "the retired format exunit-timings on format"
    assert line =~ "account #{ctx.account.id}"
    assert line =~ "project #{ctx.project.id}"
    assert line =~ ~S|user agent "goodflows/0.5.2 (linux)[31mforged line u|
    refute line =~ "\e"
    [_, agent] = String.split(line, "user agent ", parts: 2)
    assert byte_size(agent) <= 200 + 2
    refute_leaks(log, ctx)

    log = capture_log([level: :info], fn -> send.(other) end)
    assert log =~ "an unsupported format on format,"
    refute_leaks(log, ctx)

    log = capture_log([level: :info], fn -> send.(record) end)
    assert log =~ "an unsupported format on report.records[0].format,"
    refute_leaks(log, ctx)

    # Other validation errors are not logged.
    invalid = sentinel_report() |> Map.put("job_status", @sentinel) |> Jason.encode!()
    log = capture_log([level: :info], fn -> send.(invalid) end)
    refute log =~ "Test reports: rejected"
    refute_leaks(log, ctx)
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
