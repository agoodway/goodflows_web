defmodule GoodFlowsWeb.WorkflowRunRedactionTest do
  # Not async: raises the global log level to :debug and collects Sentry events.
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  setup :verify_on_exit!

  import ExUnit.CaptureLog
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlows.WorkflowRuns.Store

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

  defp token(conn) do
    conn |> get_req_header("authorization") |> hd() |> String.trim_leading("Bearer ")
  end

  defp upload(conn, slug, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/projects/#{slug}/workflow-runs", body)
  end

  defp sentinel_document do
    full()
    |> put_in(["results", Access.at(0), "command"], @sentinel)
    |> put_in(["results", Access.at(0), "error"], @sentinel)
  end

  defp refute_leaks(text, ctx) do
    refute text =~ @sentinel
    refute text =~ ctx.token
  end

  defp sentry_probe do
    context = inspect(Sentry.Context.get_all())
    {:ok, _} = Sentry.capture_message("workflow run probe", result: :sync)
    events = inspect(Sentry.Test.pop_sentry_reports())
    {context, events}
  end

  test "upload, retry, conflict, list and show keep command text out of logs and Sentry", ctx do
    body = Jason.encode!(sentinel_document())
    run_id = full()["run_id"]

    log =
      capture_log([level: :debug], fn ->
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(200)

        changed = sentinel_document() |> Map.put("outcome", "cancelled") |> Jason.encode!()
        conflict = ctx.sk_conn |> upload(ctx.project.slug, changed) |> json_response(409)
        refute_leaks(inspect(conflict), ctx)

        listed =
          ctx.sk_conn
          |> get("/api/v1/projects/#{ctx.project.slug}/workflow-runs")
          |> json_response(200)

        refute_leaks(inspect(listed), ctx)

        shown =
          ctx.pk_conn
          |> get("/api/v1/projects/#{ctx.project.slug}/workflow-runs/#{run_id}")
          |> json_response(200)

        refute_leaks(inspect(shown), ctx)
      end)

    assert log =~ "POST /api/v1/projects/#{ctx.project.slug}/workflow-runs"
    refute_leaks(log, ctx)

    {context, events} = sentry_probe()
    assert events =~ "workflow run probe"
    refute_leaks(context, ctx)
    refute_leaks(events, ctx)
  end

  test "an sk_ show keeps command text out of debug logs and Sentry", ctx do
    body = Jason.encode!(sentinel_document())
    run_id = full()["run_id"]

    log =
      capture_log([level: :debug], fn ->
        ctx.sk_conn |> upload(ctx.project.slug, body) |> json_response(201)

        shown =
          ctx.sk_conn
          |> get("/api/v1/projects/#{ctx.project.slug}/workflow-runs/#{run_id}")
          |> json_response(200)

        assert hd(shown["data"]["document"]["results"])["command"] == @sentinel
        assert hd(shown["data"]["document"]["results"])["error"] == @sentinel
      end)

    assert log =~ "GET /api/v1/projects/#{ctx.project.slug}/workflow-runs/#{run_id}"
    refute_leaks(log, ctx)

    {context, events} = sentry_probe()
    refute_leaks(context, ctx)
    refute_leaks(events, ctx)
  end

  test "validation, parser and storage errors do not reveal command text", ctx do
    invalid =
      sentinel_document()
      |> Map.put("secret_token_xyz", @sentinel)
      |> Jason.encode!()

    malformed = ~s({"workflow":"#{@sentinel}")

    log =
      capture_log([level: :debug], fn ->
        response = ctx.sk_conn |> upload(ctx.project.slug, invalid) |> json_response(422)
        assert response["errors"]["body"] == ["has an unknown field"]
        refute_leaks(inspect(response), ctx)

        response = ctx.sk_conn |> upload(ctx.project.slug, malformed) |> json_response(400)
        refute_leaks(inspect(response), ctx)

        expect(Store, :insert_all, fn _schema, _rows, _opts ->
          raise DBConnection.ConnectionError, "connection refused"
        end)

        response =
          ctx.sk_conn
          |> upload(ctx.project.slug, Jason.encode!(sentinel_document()))
          |> json_response(503)

        refute_leaks(inspect(response), ctx)
      end)

    refute log =~ "secret_token_xyz"
    refute_leaks(log, ctx)

    {context, events} = sentry_probe()
    refute_leaks(context, ctx)
    refute_leaks(events, ctx)
  end
end
