defmodule GoodFlowsWeb.VerifyRunHygieneTest do
  # Changes the global Logger level and object store config.
  use GoodFlowsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.Repo
  alias GoodFlows.VerifyRuns.Run

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account, %{"slug" => "vr-hygiene"})
    cr = create_cr(ctx.sk_conn, project.slug, %{"openspec_change" => "add-export"})

    digest =
      ctx.sk_conn
      |> post_json(
        cr_path(project.slug, cr["number"], "/scenario-sets"),
        set_body(intent_fm("add-export", [scenario("S1")]))
      )
      |> json_response(201)
      |> get_in(["data", "digest"])

    %{project: project, digest: digest}
  end

  @path "/api/v1/projects/vr-hygiene/verify-runs"

  defp doc(ctx, opts \\ []), do: run_doc(ctx.digest, "intent", sha(1), [result("S1")], opts)

  defp at_debug(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  test "upload, commit and show at :debug never log a presigned URL", ctx do
    bytes = "transcript bytes"
    document = doc(ctx, artifacts: [artifact("t", bytes, "text/plain")])

    log =
      at_debug(fn ->
        body = ctx.sk_conn |> post_json(@path, document) |> json_response(201)
        [upload] = body["data"]["uploads"]
        assert upload["upload_url"] =~ Fake.signature()
        :ok = Fake.put(upload["upload_url"], upload["upload_headers"], bytes)

        ctx.sk_conn
        |> post_json(@path <> "/#{document["run_id"]}/commit", %{})
        |> json_response(200)

        shown = ctx.sk_conn |> get(@path <> "/#{document["run_id"]}") |> json_response(200)
        assert hd(shown["data"]["artifacts"])["download_url"] =~ Fake.signature()
        send(self(), {:sentry, Sentry.Context.get_all()})
      end)

    assert log =~ "POST #{@path}"
    refute log =~ Fake.signature()
    refute log =~ "fake-object-store.invalid"
    assert_received {:sentry, sentry}
    refute inspect(sentry) =~ Fake.signature()
  end

  test "a store failure during commit is 503 with retry-after and no URL", ctx do
    bytes = "x"
    document = doc(ctx, artifacts: [artifact("t", bytes, "text/plain")])
    ctx.sk_conn |> post_json(@path, document) |> json_response(201)

    prefix = "verify-runs/#{ctx.project.id}/"
    Fake.fail(:head, prefix)
    on_exit(fn -> Fake.heal(:head, prefix) end)

    conn = ctx.sk_conn |> post_json(@path <> "/#{document["run_id"]}/commit", %{})
    assert json_response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["1"]
    refute conn.resp_body =~ Fake.signature()
  end

  describe "without a bucket" do
    setup do
      original = ObjectStore.config()
      Application.put_env(:good_flows, ObjectStore, Keyword.put(original, :bucket, nil))
      on_exit(fn -> Application.put_env(:good_flows, ObjectStore, original) end)
    end

    test "a run without artifacts is final; with artifacts 503 and nothing stored", ctx do
      assert %{"data" => %{"status" => "final"}} =
               ctx.sk_conn |> post_json(@path, doc(ctx)) |> json_response(201)

      with_artifact = doc(ctx, artifacts: [artifact("t", "x", "text/plain")])
      assert ctx.sk_conn |> post_json(@path, with_artifact) |> json_response(503)
      assert Repo.aggregate(Run, :count) == 1
    end
  end
end
