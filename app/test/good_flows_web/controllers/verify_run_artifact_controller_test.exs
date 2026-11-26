defmodule GoodFlowsWeb.VerifyRunArtifactControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures, only: [sha: 1]
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures
  import Ecto.Query, only: [from: 2]

  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ChangeRequests
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets
  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.Artifact

  setup :api_setup
  setup :register_and_log_in_user

  setup %{account: account, user: user, sk_key: key} do
    _membership = account_user_fixture(account, user, :member)
    project = project_fixture(account, %{slug: "web"})

    {:ok, cr} =
      ChangeRequests.create(account, project, key, %{
        "title" => "Export",
        "source_branch" => "feat/export",
        "change_id" => "add-export"
      })

    {:ok, :created, set} =
      ScenarioSets.upload(cr, key, set_body(intent_fm("add-export", [scenario("S1")])))

    shot = :crypto.strong_rand_bytes(2_000)
    declared = artifact("shot-3", shot)

    doc = fn ->
      run_doc(set.digest, "intent", sha(1), [result("S1", "failed", ["shot-3"])],
        artifacts: [declared]
      )
    end

    {:ok, %{run: run, uploads: [upload]}} = VerifyRuns.ingest(account, project, key, doc.())
    :ok = Fake.put(upload.upload_url, upload.upload_headers, shot)
    {:ok, run} = VerifyRuns.commit(project, key, run.run_id)

    %{project: project, run: run, declared: declared, doc: doc}
  end

  defp artifact_url(ctx, run_id, artifact_id, account_id \\ nil),
    do:
      "/dashboard/accounts/#{account_id || ctx.account.id}/projects/#{ctx.project.slug}" <>
        "/verify-runs/#{run_id}/artifacts/#{artifact_id}"

  test "a member is redirected to a presigned URL of the artifact's object", ctx do
    conn = get(ctx.conn, artifact_url(ctx, ctx.run.run_id, "shot-3"))
    url = redirected_to(conn, 302)

    assert conn.private[:phoenix_controller] == GoodFlowsWeb.VerifyRunArtifactController
    assert url =~ "X-Amz-Signature"
    object_key = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")
    expected = ctx.declared["sha256"] |> Base.decode16!(case: :lower) |> Base.encode64()
    assert {:ok, %{checksum_sha256: ^expected}} = Fake.head(object_key)
  end

  test "an expired artifact is 404", ctx do
    Repo.update_all(from(a in Artifact, where: a.artifact_id == "shot-3"), set: [expired: true])
    assert ctx.conn |> get(artifact_url(ctx, ctx.run.run_id, "shot-3")) |> response(404)
  end

  test "an artifact of an uploading run is 404", ctx do
    {:ok, %{run: uploading}} =
      VerifyRuns.ingest(ctx.account, ctx.project, ctx.sk_key, ctx.doc.())

    assert uploading.status == "uploading"
    assert ctx.conn |> get(artifact_url(ctx, uploading.run_id, "shot-3")) |> response(404)
  end

  test "an unknown artifact, run or project is 404", ctx do
    assert ctx.conn |> get(artifact_url(ctx, ctx.run.run_id, "shot-9")) |> response(404)
    assert ctx.conn |> get(artifact_url(ctx, Ecto.UUID.generate(), "shot-3")) |> response(404)
    assert ctx.conn |> get(artifact_url(ctx, "not-a-uuid", "shot-3")) |> response(404)

    unknown_project =
      String.replace(artifact_url(ctx, ctx.run.run_id, "shot-3"), "/web/", "/nope/")

    assert ctx.conn |> get(unknown_project) |> response(404)
  end

  test "a project of another account redirects to /dashboard", ctx do
    other = account_fixture()
    conn = get(ctx.conn, artifact_url(ctx, ctx.run.run_id, "shot-3", other.id))
    assert redirected_to(conn) == "/dashboard"

    refute Enum.any?(get_resp_header(conn, "location"), &(&1 =~ "X-Amz-Signature"))
    refute conn.private[:phoenix_controller] == GoodFlowsWeb.VerifyRunArtifactController
  end

  test "a signed-out user is redirected to log in", ctx do
    conn = get(build_conn(), artifact_url(ctx, ctx.run.run_id, "shot-3"))
    assert redirected_to(conn) == "/users/log-in"
  end
end
