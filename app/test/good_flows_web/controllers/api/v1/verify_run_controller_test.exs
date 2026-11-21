defmodule GoodFlowsWeb.Api.V1.VerifyRunControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.Repo
  alias GoodFlows.VerifyRuns.{Artifact, Run}
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    cr = create_cr(ctx.sk_conn, project.slug, %{"openspec_change" => "add-export"})
    fm = intent_fm("add-export", [scenario("S1"), scenario("S2", "should")])

    digest =
      ctx.sk_conn
      |> post_json(cr_path(project.slug, cr["number"], "/scenario-sets"), set_body(fm))
      |> json_response(201)
      |> get_in(["data", "digest"])

    %{project: project, digest: digest}
  end

  defp runs_path(ctx, suffix \\ ""),
    do: "/api/v1/projects/#{ctx.project.slug}/verify-runs" <> suffix

  defp doc(ctx, opts \\ []),
    do: run_doc(ctx.digest, "intent", sha(1), [result("S1"), result("S2", "failed")], opts)

  test "sk_ uploads, pk_ reads, pk_ and ck_ refused, slug rules", ctx do
    assert ctx.pk_conn |> post_json(runs_path(ctx), "{") |> json_response(403)

    created = ctx.sk_conn |> post_json(runs_path(ctx), doc(ctx)) |> json_response(201)
    assert_schema(created, "VerifyRunAcknowledgement", ApiSpec.spec())
    assert %{"status" => "final", "duplicate" => false, "uploads" => []} = created["data"]

    list = ctx.pk_conn |> get(runs_path(ctx)) |> json_response(200)
    assert_schema(list, "VerifyRunListResponse", ApiSpec.spec())

    assert [%{"counts" => %{"passed" => 1, "failed" => 1, "not_run" => 0}}] = list["data"]

    owner = Repo.preload(ctx.sk_key, :account_user).account_user
    {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
    assert api_conn(ck) |> get(runs_path(ctx)) |> json_response(403)

    assert ctx.sk_conn
           |> post_json("/api/v1/projects/Bad Slug/verify-runs", "{")
           |> json_response(422)

    assert ctx.sk_conn
           |> post_json("/api/v1/projects/nope/verify-runs", "{")
           |> json_response(404)

    assert ctx.other_conn |> get(runs_path(ctx)) |> json_response(404)
  end

  test "body rules and status codes", ctx do
    assert %{"errors" => %{"body" => _}} =
             ctx.sk_conn
             |> post_json(runs_path(ctx), Map.put(doc(ctx), "change_request", 42))
             |> json_response(422)

    assert ctx.sk_conn |> post_json(runs_path(ctx), "{") |> json_response(400)

    conn =
      ctx.sk_conn |> put_req_header("content-type", "text/plain") |> post(runs_path(ctx), "x")

    assert json_response(conn, 415)

    big = doc(ctx, artifacts: [%{artifact("a", "x") | "size" => 52_428_801}])
    assert ctx.sk_conn |> post_json(runs_path(ctx), big) |> json_response(413)

    document = doc(ctx)
    ctx.sk_conn |> post_json(runs_path(ctx), document) |> json_response(201)

    assert %{"data" => %{"duplicate" => true}} =
             ctx.sk_conn |> post_json(runs_path(ctx), document) |> json_response(200)

    conflict = %{document | "drift" => ["changed"]}
    body = ctx.sk_conn |> post_json(runs_path(ctx), conflict) |> json_response(409)
    refute inspect(body) =~ document["run_id"]
    assert Repo.aggregate(Run, :count) == 1
  end

  test "artifact upload, commit and download", ctx do
    shot = :crypto.strong_rand_bytes(500)
    document = doc(ctx, artifacts: [artifact("shot-1", shot)])
    created = ctx.sk_conn |> post_json(runs_path(ctx), document) |> json_response(201)
    assert %{"status" => "uploading", "uploads" => [upload], "expires_at" => _} = created["data"]
    assert upload["upload_headers"]["content-length"] == "500"

    run_id = document["run_id"]
    commit = runs_path(ctx, "/#{run_id}/commit")

    assert %{"errors" => %{"artifacts" => [msg]}} =
             ctx.sk_conn |> post_json(commit, %{}) |> json_response(422)

    assert msg =~ "shot-1"

    shown = ctx.sk_conn |> get(runs_path(ctx, "/#{run_id}")) |> json_response(200)
    assert [%{"id" => "shot-1", "expired" => false} = a] = shown["data"]["artifacts"]
    refute Map.has_key?(a, "download_url")

    :ok = Fake.put(upload["upload_url"], upload["upload_headers"], shot)
    committed = ctx.sk_conn |> post_json(commit, %{}) |> json_response(200)
    assert_schema(committed, "VerifyRunResponse", ApiSpec.spec())
    assert committed["data"]["status"] == "final"
    assert ctx.sk_conn |> post_json(commit, %{}) |> json_response(200)
    assert ctx.member_sk_conn |> post_json(commit, %{}) |> json_response(404)

    shown = ctx.sk_conn |> get(runs_path(ctx, "/#{run_id}")) |> json_response(200)
    assert [%{"download_url" => url, "download_url_expires_at" => _}] = shown["data"]["artifacts"]
    assert url =~ Fake.signature()

    pk = ctx.pk_conn |> get(runs_path(ctx, "/#{run_id}")) |> json_response(200)
    assert [%{"id" => "shot-1", "expired" => false} = pk_artifact] = pk["data"]["artifacts"]
    refute Map.has_key?(pk_artifact, "download_url")

    Repo.update_all(Artifact, set: [expired: true])
    shown = ctx.sk_conn |> get(runs_path(ctx, "/#{run_id}")) |> json_response(200)
    assert [%{"expired" => true} = expired] = shown["data"]["artifacts"]
    refute Map.has_key?(expired, "download_url")
    assert shown["data"]["document"] == document
  end

  test "show 404s; list filters and paging", ctx do
    assert ctx.sk_conn |> get(runs_path(ctx, "/#{Ecto.UUID.generate()}")) |> json_response(404)
    assert ctx.sk_conn |> get(runs_path(ctx, "/NOT-A-UUID")) |> json_response(404)

    for {commit, minute} <- [{sha(1), 1}, {sha(2), 2}, {sha(1), 3}] do
      d =
        put_in(
          doc(ctx, finished_at: "2026-11-20T10:0#{minute}:00Z"),
          ["source", "commit"],
          commit
        )

      ctx.sk_conn |> post_json(runs_path(ctx), d) |> json_response(201)
    end

    assert %{"data" => [_, _]} =
             ctx.sk_conn |> get(runs_path(ctx, "?commit=#{sha(1)}")) |> json_response(200)

    page = ctx.sk_conn |> get(runs_path(ctx, "?limit=2")) |> json_response(200)
    assert [first, _] = page["data"]
    assert first["finished_at"] == "2026-11-20T10:03:00Z"

    next =
      ctx.sk_conn
      |> get(runs_path(ctx, "?limit=2&cursor=#{page["next_cursor"]}"))
      |> json_response(200)

    assert [%{"finished_at" => "2026-11-20T10:01:00Z"}] = next["data"]

    assert ctx.sk_conn |> get(runs_path(ctx, "?status=bogus")) |> json_response(422)
    assert ctx.sk_conn |> get(runs_path(ctx, "?limit=0")) |> json_response(422)
  end

  describe "public key redaction" do
    test "results, features, changed files, threads and absent links", ctx do
      document =
        doc(ctx,
          features: [%{"id" => "checkout", "entry_point" => "/checkout", "result" => "passed"}],
          links: %{"threads" => ["https://ampcode.com/threads/T-1"], "tickets" => ["GF-1"]}
        )

      ctx.sk_conn |> post_json(runs_path(ctx), document) |> json_response(201)

      pk = ctx.pk_conn |> get(runs_path(ctx, "/#{document["run_id"]}")) |> json_response(200)
      d = pk["data"]["document"]

      assert [
               %{"id" => "S1", "result" => "passed"},
               %{"id" => "S2", "result" => "failed"} = failed
             ] =
               d["results"]

      assert failed["reason"] == nil and failed["failed_step"] == nil
      assert d["features"] == [%{"id" => "checkout", "entry_point" => nil, "result" => "passed"}]
      assert d["source"]["changed_files"] == nil
      assert d["links"] == %{"threads" => nil, "tickets" => ["GF-1"]}

      sk = ctx.sk_conn |> get(runs_path(ctx, "/#{document["run_id"]}")) |> json_response(200)
      assert Enum.at(sk["data"]["document"]["results"], 1)["reason"] == "it broke"

      plain = doc(ctx)
      ctx.sk_conn |> post_json(runs_path(ctx), plain) |> json_response(201)
      pk = ctx.pk_conn |> get(runs_path(ctx, "/#{plain["run_id"]}")) |> json_response(200)
      refute Map.has_key?(pk["data"]["document"], "links")
    end
  end
end
