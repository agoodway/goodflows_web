defmodule GoodFlows.VerifyRuns.SweepTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.ScenarioSets
  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.{Artifact, Run, Sweep}

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "SW #{System.unique_integer()}"})
    owner = Accounts.get_account_user(user, account)
    {key, _} = api_key_fixture(owner, %{type: :private})
    project = project_fixture(account)
    cr = cr!(account, project, key)
    fm = intent_fm("add-export", [scenario("S1")])
    {:ok, :created, set} = ScenarioSets.upload(cr, key, set_body(fm))
    %{account: account, key: key, project: project, cr: cr, digest: set.digest}
  end

  defp cr!(account, project, key) do
    {:ok, cr} =
      ChangeRequests.create(account, project, key, %{
        "title" => "Export",
        "source_branch" => "feat/export-#{System.unique_integer([:positive])}",
        "change_id" => "add-export"
      })

    cr
  end

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp queued?(object_key),
    do: Repo.exists?(from d in "cache_object_deletions", where: d.object_key == ^object_key)

  defp uploading!(ctx) do
    bytes = "shot #{System.unique_integer()}"
    doc = run_doc(ctx.digest, "intent", sha(1), [result("S1")], artifacts: [artifact("a", bytes)])

    {:ok, %{run: run, uploads: [upload]}} =
      VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)

    {run, upload, bytes}
  end

  # A final run with one stored artifact, finalized `days` ago.
  defp final!(ctx, days) do
    {run, upload, bytes} = uploading!(ctx)
    :ok = Fake.put(upload.upload_url, upload.upload_headers, bytes)
    {:ok, _} = VerifyRuns.commit(ctx.project, ctx.key, run.run_id)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [finalized_at: ago(days)])
    artifact = Repo.get_by!(Artifact, verify_run_id: run.id)
    assert Fake.exists?(artifact.object_key)
    {run, artifact}
  end

  defp count!(cr, run) do
    Repo.insert_all("verify_run_counts", [
      %{
        change_request_id: Ecto.UUID.dump!(cr.id),
        verify_run_id: Ecto.UUID.dump!(run.id),
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  defp merged!(cr, days) do
    Repo.update_all(from(c in ChangeRequest, where: c.id == ^cr.id),
      set: [state: "merged", merged_at: ago(days)]
    )
  end

  defp closed!(cr, days) do
    Repo.update_all(from(c in ChangeRequest, where: c.id == ^cr.id),
      set: [state: "closed", updated_at: ago(days)]
    )
  end

  defp expired?(artifact), do: Repo.reload!(artifact).expired

  test "an expired uploading run is deleted and its objects are queued", ctx do
    {run, upload, bytes} = uploading!(ctx)
    :ok = Fake.put(upload.upload_url, upload.upload_headers, bytes)
    artifact = Repo.get_by!(Artifact, verify_run_id: run.id)
    {live, _, _} = uploading!(ctx)

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert %{verify_runs_expired: 1} = Sweep.run()
    refute Repo.get(Run, run.id)
    assert Repo.get(Run, live.id)
    assert queued?(artifact.object_key)
    assert Sweep.run().verify_runs_expired == 0
  end

  test "a run finalized after the sweep selected it is not deleted", ctx do
    {run, _artifact} = final!(ctx, 0)
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [expires_at: past])
    selected = from r in Run, where: r.id == ^run.id, select: r.id

    assert {0, _} = Sweep.delete_expired_uploading(selected, DateTime.utc_now())
    assert Repo.get(Run, run.id).status == "final"
  end

  test "30 days after every counting change request is merged or closed", ctx do
    {run, artifact} = final!(ctx, 60)
    count!(ctx.cr, run)

    merged!(ctx.cr, 29)
    Sweep.run()
    refute expired?(artifact)

    merged!(ctx.cr, 31)
    assert %{artifacts_expired: 1} = Sweep.run()
    assert expired?(artifact)
    refute Fake.exists?(artifact.object_key)
    assert Repo.get(Run, run.id).document
    assert Sweep.run().artifacts_expired == 0
  end

  test "one counting change request still open keeps the artifacts", ctx do
    {run, artifact} = final!(ctx, 60)
    other = cr!(ctx.account, ctx.project, ctx.key)
    count!(ctx.cr, run)
    count!(other, run)
    merged!(ctx.cr, 40)

    Sweep.run()
    refute expired?(artifact)

    closed!(other, 31)
    Sweep.run()
    assert expired?(artifact)
  end

  test "a run no change request counted is kept 14 days after finalized_at", ctx do
    {_, young} = final!(ctx, 13)
    {_, old} = final!(ctx, 15)

    Sweep.run()
    refute expired?(young)
    assert expired?(old)
    assert Fake.exists?(young.object_key)
    refute Fake.exists?(old.object_key)
  end

  test "a change request closed 20 days ago then reopened keeps the artifacts", ctx do
    {run, artifact} = final!(ctx, 60)
    count!(ctx.cr, run)
    closed!(ctx.cr, 20)
    Repo.update_all(from(c in ChangeRequest, where: c.id == ^ctx.cr.id), set: [state: "open"])

    Sweep.run()
    refute expired?(artifact)
  end

  test "a failed store delete is retried by a later sweep", ctx do
    {_, artifact} = final!(ctx, 15)
    Fake.fail_deletes(artifact.object_key)

    assert %{artifacts_failed: 1, artifacts_expired: 0} = Sweep.run()
    refute expired?(artifact)

    Fake.heal(artifact.object_key)
    assert %{artifacts_expired: 1} = Sweep.run()
    assert expired?(artifact)
  end
end
