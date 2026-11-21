defmodule GoodFlows.VerifyRunsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ScenarioSets
  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.{Artifact, Run}

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "VR #{System.unique_integer()}"})
    owner = Accounts.get_account_user(user, account)
    {key, _} = api_key_fixture(owner, %{type: :private})
    {other_key, _} = api_key_fixture(owner, %{type: :private})
    project = project_fixture(account)

    {:ok, cr} =
      ChangeRequests.create(account, project, key, %{
        "title" => "Export",
        "source_branch" => "feat/export",
        "openspec_change" => "add-export"
      })

    fm = intent_fm("add-export", [scenario("S1"), scenario(2, "should")])
    {:ok, :created, set} = ScenarioSets.upload(cr, key, set_body(fm))

    %{
      account: account,
      key: key,
      other_key: other_key,
      project: project,
      cr: cr,
      digest: set.digest
    }
  end

  defp doc(ctx, opts \\ []),
    do: run_doc(ctx.digest, "intent", sha(1), [result("S1"), result("2")], opts)

  defp ingest(ctx, document, key \\ nil),
    do: VerifyRuns.ingest(ctx.account, ctx.project, key || ctx.key, document)

  defp invalid(ctx, document) do
    assert {:error, {:invalid_body, errors}} = ingest(ctx, document)
    errors
  end

  describe "scenario set checks" do
    test "unknown digest, wrong source, other project", ctx do
      assert %{"scenario_set.digest" => _} =
               invalid(
                 ctx,
                 put_in(doc(ctx), ["scenario_set", "digest"], String.duplicate("e", 64))
               )

      assert %{"scenario_set.digest" => _} =
               invalid(ctx, put_in(doc(ctx), ["scenario_set", "source"], "diff"))

      beta = project_fixture(ctx.account)

      assert {:error, {:invalid_body, %{"scenario_set.digest" => _}}} =
               VerifyRuns.ingest(ctx.account, beta, ctx.key, doc(ctx))

      assert Repo.aggregate(Run, :count) == 0
    end

    test "results must hold exactly the set's IDs in string form", ctx do
      assert %{"results" => _} = invalid(ctx, %{doc(ctx) | "results" => [result("S1")]})

      assert %{"results" => _} =
               invalid(ctx, %{doc(ctx) | "results" => [result("S1"), result("2"), result("S9")]})

      assert {:ok, %{duplicate: false}} =
               ingest(ctx, %{doc(ctx) | "results" => [result("S1"), result(2)]})
    end
  end

  describe "idempotency" do
    test "201, duplicate with reordered keys, 409 conflict, other project 201", ctx do
      document = doc(ctx)
      assert {:ok, %{run: run, duplicate: false}} = ingest(ctx, document)
      assert run.status == "final" and run.finalized_at != nil

      reordered = document |> Enum.reverse() |> Map.new()
      assert {:ok, %{run: same, duplicate: true}} = ingest(ctx, reordered)
      assert same.id == run.id

      changed = %{document | "results" => [result("S1", "failed"), result("2")]}
      assert {:error, :verify_run_conflict} = ingest(ctx, changed)
      assert Repo.reload!(run).document == document

      other = project_fixture(ctx.account)

      {:ok, other_cr} =
        ChangeRequests.create(ctx.account, other, ctx.key, %{
          "title" => "x",
          "source_branch" => "b",
          "openspec_change" => "add-export"
        })

      {:ok, :created, _} =
        ScenarioSets.upload(
          other_cr,
          ctx.key,
          set_body(intent_fm("add-export", [scenario("S1"), scenario(2, "should")]))
        )

      assert {:ok, %{duplicate: false}} = VerifyRuns.ingest(ctx.account, other, ctx.key, document)
    end
  end

  describe "artifacts" do
    setup ctx do
      shot = :crypto.strong_rand_bytes(1_200)
      transcript = "hello transcript"

      document =
        doc(ctx,
          artifacts: [artifact("shot-1", shot), artifact("transcript", transcript, "text/plain")]
        )

      %{shot: shot, transcript: transcript, document: document}
    end

    test "uploading with signed headers; retry gives fresh URLs", ctx do
      assert {:ok, %{run: run, uploads: [u1, u2], duplicate: false}} = ingest(ctx, ctx.document)
      assert run.status == "uploading"
      assert run.expires_at
      assert DateTime.diff(run.expires_at, DateTime.utc_now()) in 7_100..7_200

      assert u1.artifact_id == "shot-1"
      assert u1.upload_headers["content-length"] == "1200"
      assert u1.upload_headers["content-type"] == "image/png"

      assert u1.upload_headers["x-amz-checksum-sha256"] ==
               Base.encode64(:crypto.hash(:sha256, ctx.shot))

      assert u2.upload_headers["content-type"] == "text/plain"
      assert u1.upload_url =~ "verify-runs/#{ctx.project.id}/"

      assert {:error, :bad_digest} =
               Fake.put(u1.upload_url, u1.upload_headers, String.duplicate("x", 1_200))

      assert {:ok, %{duplicate: true, uploads: [r1, _r2]}} = ingest(ctx, ctx.document)
      assert r1.upload_url =~ "X-Amz-Signature"
      assert Repo.aggregate(Run, :count) == 1
    end

    test "commit: missing artifact 422, then 200, then retry 200", ctx do
      {:ok, %{run: run, uploads: [u1, u2]}} = ingest(ctx, ctx.document)
      :ok = Fake.put(u1.upload_url, u1.upload_headers, ctx.shot)

      assert {:error, {:invalid_body, %{"artifacts" => [message]}}} =
               VerifyRuns.commit(ctx.project, ctx.key, run.run_id)

      assert message =~ "transcript"
      refute message =~ "shot-1"
      assert Repo.reload!(run).status == "uploading"

      :ok = Fake.put(u2.upload_url, u2.upload_headers, ctx.transcript)
      assert {:ok, %Run{status: "final"}} = VerifyRuns.commit(ctx.project, ctx.key, run.run_id)
      assert {:ok, %Run{status: "final"}} = VerifyRuns.commit(ctx.project, ctx.key, run.run_id)
    end

    test "commit 404: other key, unknown, non-canonical, expired", ctx do
      {:ok, %{run: run}} = ingest(ctx, ctx.document)
      assert {:error, :not_found} = VerifyRuns.commit(ctx.project, ctx.other_key, run.run_id)
      assert {:error, :not_found} = VerifyRuns.commit(ctx.project, ctx.key, Ecto.UUID.generate())

      assert {:error, :not_found} =
               VerifyRuns.commit(ctx.project, ctx.key, String.upcase(run.run_id))

      assert Repo.reload!(run).status == "uploading"

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [expires_at: past])
      assert {:error, :not_found} = VerifyRuns.commit(ctx.project, ctx.key, run.run_id)

      assert {:ok, %{duplicate: false, run: fresh}} = ingest(ctx, ctx.document)
      refute fresh.id == run.id
    end

    test "store unreachable: 503 and the run stays uploading", ctx do
      {:ok, %{run: run, uploads: uploads}} = ingest(ctx, ctx.document)

      for {u, body} <- Enum.zip(uploads, [ctx.shot, ctx.transcript]),
          do: :ok = Fake.put(u.upload_url, u.upload_headers, body)

      prefix = "verify-runs/#{ctx.project.id}/"
      Fake.fail(:head, prefix)
      on_exit(fn -> Fake.heal(:head, prefix) end)

      assert {:error, :object_store_unavailable} =
               VerifyRuns.commit(ctx.project, ctx.key, run.run_id)

      assert Repo.reload!(run).status == "uploading"
    end

    test "schema: artifact rows and the counted-run join table", ctx do
      {:ok, %{run: run}} = ingest(ctx, ctx.document)

      artifacts =
        Repo.all(from a in Artifact, where: a.verify_run_id == ^run.id, order_by: a.artifact_id)

      assert Enum.map(artifacts, & &1.artifact_id) == ["shot-1", "transcript"]
      assert Enum.all?(artifacts, &(not &1.expired and &1.upload_expires_at != nil))
      assert hd(artifacts).size == 1_200

      Repo.insert_all("verify_run_counts", [
        %{
          change_request_id: Ecto.UUID.dump!(ctx.cr.id),
          verify_run_id: Ecto.UUID.dump!(run.id),
          inserted_at: DateTime.utc_now()
        }
      ])

      Repo.delete!(run)
      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate("verify_run_counts", :count) == 0

      queued =
        Repo.all(
          from d in "cache_object_deletions",
            where: like(d.object_key, ^"verify-runs/#{ctx.project.id}/%"),
            select: d.object_key
        )

      assert length(queued) == 2
    end
  end

  describe "list and show" do
    test "keyset paging, filters, counts", ctx do
      docs =
        for minute <- 1..3 do
          doc(ctx, finished_at: "2026-11-20T10:0#{minute}:00Z")
        end

      runs = for d <- docs, do: elem(ingest(ctx, d), 1).run

      dirty = doc(ctx, finished_at: "2026-11-20T10:00:00Z", dirty: true)
      dirty = put_in(dirty, ["source", "commit"], sha(2))

      {:ok, _} =
        ingest(ctx, %{dirty | "results" => [result("S1", "failed"), result("2", "not_run")]})

      {:ok, page1} = VerifyRuns.list(ctx.project, %{"limit" => "2"})

      assert Enum.map(page1.runs, & &1.run_id) ==
               Enum.map(Enum.reverse(runs), & &1.run_id) |> Enum.take(2)

      {:ok, page2} =
        VerifyRuns.list(ctx.project, %{"limit" => "2", "cursor" => page1.next_cursor})

      assert length(page2.runs) == 2
      assert page2.next_cursor == nil

      {:ok, %{runs: [only]}} = VerifyRuns.list(ctx.project, %{"commit" => sha(2)})
      assert VerifyRuns.result_counts(only) == %{"passed" => 0, "failed" => 1, "not_run" => 1}

      assert {:error, _} = VerifyRuns.list(ctx.project, %{"cursor" => "bad"})
      assert {:error, _} = VerifyRuns.list(ctx.project, %{"commit" => "abc"})

      {:ok, %{runs: four}} =
        VerifyRuns.list(ctx.project, %{"digest" => ctx.digest, "status" => "final"})

      assert length(four) == 4
    end
  end
end
