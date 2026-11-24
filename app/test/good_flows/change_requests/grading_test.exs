defmodule GoodFlows.ChangeRequests.GradingTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ChangeRequests
  alias GoodFlows.FeatureIndex
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ScenarioSets
  alias GoodFlows.VerifyRuns

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "GR #{System.unique_integer()}"})
    owner = Accounts.get_account_user(user, account)
    {key, _} = api_key_fixture(owner, %{type: :private})
    project = project_fixture(account)

    {:ok, :created, _} =
      ReviewPolicies.write(project, owner, key, %{
        "previous_version" => 0,
        "policy" => %{
          "format" => "review-policy/1",
          "paths" => [],
          "scenarios" => %{"require_approved_intent" => true}
        }
      })

    {:ok, cr} =
      ChangeRequests.create(account, project, key, %{
        "title" => "Export",
        "source_branch" => "feat/export",
        "openspec_change" => "add-export"
      })

    %{account: account, owner: owner, key: key, project: project, cr: cr}
  end

  defp reload(ctx), do: Repo.reload!(ctx.cr)
  defp verdict(ctx), do: ChangeRequests.verdict(reload(ctx))
  defp rules(ctx), do: Enum.map(verdict(ctx).reasons, &{&1["rule"], &1["subject"]})

  defp explained_with_counts_asserted(ctx) do
    runs = ctx |> reload() |> ChangeRequests.verify_runs()
    counts = for %{explanation: :counts, run_id: run_id} <- runs, do: run_id
    assert Enum.sort(counts) == Enum.sort(verdict(ctx).counted_runs)
    Map.new(runs, &{&1.run_id, &1.explanation})
  end

  defp upload_set!(ctx, opts \\ []) do
    fm =
      intent_fm(
        "add-export",
        Keyword.get(opts, :scenarios, [scenario("S1")]),
        Keyword.get(opts, :extra, %{})
      )

    {:ok, _, version} = ScenarioSets.upload(reload(ctx), ctx.key, set_body(fm, opts))
    version.digest
  end

  defp approve!(ctx, digest) do
    {:ok, :created, _} =
      ScenarioSets.decide(reload(ctx), ctx.owner, ctx.key, :approve, %{"digest" => digest})
  end

  # Facts for head `h` with commits `a` (lib/a.ex) then `h` (`h_files`).
  defp facts!(ctx, a, h, h_files) do
    files = [file("lib/a.ex") | Enum.map(h_files, &file/1)]

    doc = %{
      "format" => "git-facts/1",
      "head" => h,
      "target" => %{"branch" => "main", "merge_base" => sha(0)},
      "commits" => [
        %{"sha" => a, "parents" => [sha(0)], "changed_files" => [file("lib/a.ex")]},
        %{"sha" => h, "parents" => [a], "changed_files" => Enum.map(h_files, &file/1)}
      ],
      "diff" => %{"files" => files}
    }

    {:ok, _, _} = ChangeRequests.report_git_facts(reload(ctx), ctx.key, doc)
    {:ok, _, _} = ChangeRequests.upload_claims(reload(ctx), ctx.key, claims(front_matter(h)))
  end

  defp head_facts!(ctx, head) do
    {:ok, _, _} = ChangeRequests.report_git_facts(reload(ctx), ctx.key, git_facts(head))
    {:ok, _, _} = ChangeRequests.upload_claims(reload(ctx), ctx.key, claims(front_matter(head)))
  end

  defp run!(ctx, digest, commit, opts \\ []) do
    outcome = Keyword.get(opts, :outcome, "passed")
    doc = run_doc(digest, "intent", commit, [result("S1", outcome)], opts)
    {:ok, ingested} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)
    ingested.run
  end

  describe "runs that count" do
    setup ctx do
      digest = upload_set!(ctx)
      approve!(ctx, digest)
      %{digest: digest}
    end

    test "a final clean run on the head counts", ctx do
      head_facts!(ctx, sha(1))
      assert {"scenario_results_missing", ["intent"]} in rules(ctx)
      run = run!(ctx, ctx.digest, sha(1))
      assert verdict(ctx).counted_runs == [run.run_id]
      assert verdict(ctx).state == "mergeable"
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :counts}
    end

    test "dirty, merge-result and uploading runs do not count", ctx do
      head_facts!(ctx, sha(1))
      dirty = run!(ctx, ctx.digest, sha(1), dirty: true)

      merge =
        run!(ctx, ctx.digest, sha(1), merge_result: %{"base" => sha(3), "commit" => sha(4)})

      uploading = run!(ctx, ctx.digest, sha(1), artifacts: [artifact("a", "x")], dirty: true)

      assert verdict(ctx).counted_runs == []
      assert {"scenario_results_missing", ["intent"]} in rules(ctx)

      assert explained_with_counts_asserted(ctx) == %{
               dirty.run_id => :dirty,
               merge.run_id => :merge_result,
               uploading.run_id => :uploading
             }
    end

    test "docs-only commit after the run counts; a code commit does not", ctx do
      run = run!(ctx, ctx.digest, sha(10))
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :no_git_facts}
      facts!(ctx, sha(10), sha(11), ["docs/usage.md"])
      assert verdict(ctx).counted_runs == [run.run_id]
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :counts}

      facts!(ctx, sha(10), sha(12), ["app/lib/good_flows/caches.ex"])
      assert verdict(ctx).counted_runs == []
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :commit_not_counted}
    end

    test "a diff-set run counts after a docs-only push", ctx do
      {:ok, cr} =
        ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
          "title" => "Diff only",
          "source_branch" => "feat/diff"
        })

      dctx = %{ctx | cr: cr}
      body = set_body(diff_fm(sha(10), [scenario("S1")]))
      {:ok, :created, version} = ScenarioSets.upload(cr, ctx.key, body)
      doc = run_doc(version.digest, "diff", sha(10), [result("S1")])
      {:ok, %{run: run}} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)

      facts!(dctx, sha(10), sha(11), ["docs/usage.md"])
      assert verdict(dctx).counted_runs == [run.run_id]
      assert verdict(dctx).scenarios["diff"]["graded"]
      refute Enum.any?(rules(dctx), &match?({"diff_set_revision", _}, &1))
      assert explained_with_counts_asserted(dctx) == %{run.run_id => :counts}

      facts!(dctx, sha(10), sha(12), ["app/lib/good_flows/caches.ex"])
      assert verdict(dctx).counted_runs == []
      assert {"diff_set_revision", [sha(10)]} in rules(dctx)
      assert explained_with_counts_asserted(dctx) == %{run.run_id => :diff_not_at_head}
    end

    test "a commit not in the facts (rebase) does not count", ctx do
      run = run!(ctx, ctx.digest, sha(20))
      facts!(ctx, sha(10), sha(11), ["docs/usage.md"])
      assert verdict(ctx).counted_runs == []
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :commit_not_counted}
    end

    test "a stale digest does not count even if approved", ctx do
      head_facts!(ctx, sha(1))
      run = run!(ctx, ctx.digest, sha(1))
      d2 = upload_set!(ctx, body: "edited\n")
      approve!(ctx, d2)
      assert verdict(ctx).counted_runs == []
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :older_version}
    end

    test "runs counted at an earlier head stay recorded", ctx do
      head_facts!(ctx, sha(1))
      run = run!(ctx, ctx.digest, sha(1))
      head_facts!(ctx, sha(2))
      assert verdict(ctx).counted_runs == []

      assert Repo.all(from c in "verify_run_counts", select: c.verify_run_id) ==
               [Ecto.UUID.dump!(run.id)]
    end
  end

  describe "explain_runs/4" do
    test "a run on an unapproved intent set; runs on another change request's set", ctx do
      digest = upload_set!(ctx)
      head_facts!(ctx, sha(1))
      run = run!(ctx, digest, sha(1))
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :intent_not_approved}

      approve!(ctx, digest)
      assert explained_with_counts_asserted(ctx) == %{run.run_id => :counts}

      {:ok, other} =
        ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
          "title" => "Other",
          "source_branch" => "feat/other",
          "openspec_change" => "add-other"
        })

      assert ChangeRequests.verify_runs(other) == []
    end

    test "a listed run names its set version and counts its results", ctx do
      digest = upload_set!(ctx, scenarios: [scenario("S1"), scenario("S2", "should")])
      approve!(ctx, digest)
      head_facts!(ctx, sha(1))

      doc =
        run_doc(digest, "intent", sha(1), [result("S1", "failed"), result("S2", "not_run")],
          finished_at: "2026-11-20T10:00:00Z"
        )

      {:ok, %{run: older}} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)

      doc =
        run_doc(digest, "intent", sha(1), [result("S1"), result("S2")],
          finished_at: "2026-11-20T11:00:00Z"
        )

      {:ok, %{run: newer}} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)

      assert [first, second] = ChangeRequests.verify_runs(reload(ctx))
      assert first.run_id == newer.run_id and second.run_id == older.run_id
      assert %{source: "intent", version: 1, commit: _, explanation: :counts} = first
      assert first.counts == %{"passed" => 2, "failed" => 0, "not_run" => 0}
      assert second.counts == %{"passed" => 0, "failed" => 1, "not_run" => 1}
    end
  end

  describe "recompute triggers" do
    test "set upload, approval and rejection", ctx do
      assert {"scenario_set_approval", []} in rules(ctx)
      digest = upload_set!(ctx)
      assert {"scenario_set_approval", [digest]} in rules(ctx)
      approve!(ctx, digest)
      refute Enum.any?(rules(ctx), &(elem(&1, 0) == "scenario_set_approval"))

      {:ok, :created, _} =
        ScenarioSets.decide(reload(ctx), ctx.owner, ctx.key, :reject, %{
          "digest" => digest,
          "note" => "no"
        })

      assert {"scenario_set_approval", [digest]} in rules(ctx)
    end

    test "a no-artifact upload and a run commit", ctx do
      digest = upload_set!(ctx)
      approve!(ctx, digest)
      head_facts!(ctx, sha(1))

      run = run!(ctx, digest, sha(1), outcome: "failed")
      assert verdict(ctx).counted_runs == [run.run_id]
      assert {"must_failed", ["intent", "S1"]} in rules(ctx)

      bytes = "shot"

      doc =
        run_doc(digest, "intent", sha(1), [result("S1")],
          artifacts: [artifact("a", bytes)],
          finished_at: "2026-11-20T11:00:00Z"
        )

      {:ok, %{run: uploading, uploads: [u]}} =
        VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)

      assert verdict(ctx).counted_runs == [run.run_id]

      assert explained_with_counts_asserted(ctx) == %{
               run.run_id => :counts,
               uploading.run_id => :uploading
             }

      :ok = Fake.put(u.upload_url, u.upload_headers, bytes)
      {:ok, _} = VerifyRuns.commit(ctx.project, ctx.key, uploading.run_id)
      assert Enum.sort(verdict(ctx).counted_runs) == Enum.sort([run.run_id, uploading.run_id])

      assert explained_with_counts_asserted(ctx) == %{
               run.run_id => :counts,
               uploading.run_id => :counts
             }

      assert verdict(ctx).state == "mergeable"
    end

    test "a feature index sync", ctx do
      {:ok, :created, _} =
        ReviewPolicies.write(ctx.project, ctx.owner, ctx.key, %{
          "previous_version" => 1,
          "policy" => %{
            "format" => "review-policy/1",
            "paths" => [],
            "coverage" => %{"unmapped_areas" => "needs_review"}
          }
        })

      head_facts!(ctx, sha(1))
      assert {"feature_index_missing", []} in rules(ctx)

      {:ok, :created, _} =
        FeatureIndex.sync(ctx.project, ctx.key, %{"features" => [feature("x", ["other/**"])]})

      assert {"unmapped_area", ["lib/a.ex"]} in rules(ctx)

      {:ok, :created, _} =
        FeatureIndex.sync(ctx.project, ctx.key, %{"features" => [feature("lib", ["lib/**"])]})

      refute Enum.any?(rules(ctx), &(elem(&1, 0) == "unmapped_area"))
      assert verdict(ctx).coverage["version"] == 2
    end

    test "a claims upload recomputes spec gaps", ctx do
      {:ok, :created, _} =
        ReviewPolicies.write(ctx.project, ctx.owner, ctx.key, %{
          "previous_version" => 1,
          "policy" => %{
            "format" => "review-policy/1",
            "paths" => [],
            "scenarios" => %{"require_approved_intent" => true, "spec_gaps" => "needs_review"}
          }
        })

      row = %{
        "capability" => "exports",
        "requirement" => "Export is audited",
        "scenario" => "Audit entry written",
        "status" => "no_check",
        "scenarios" => []
      }

      digest = upload_set!(ctx, extra: %{"coverage" => [row]})
      approve!(ctx, digest)
      {:ok, _, _} = ChangeRequests.report_git_facts(reload(ctx), ctx.key, git_facts(sha(1)))
      refute Enum.any?(rules(ctx), &(elem(&1, 0) == "spec_gap"))

      covers = Map.take(row, ~w(capability requirement scenario))

      entry = %{
        "fact" => "Audit row written",
        "location" => "lib/a.ex:1",
        "proof" => "ran",
        "evidence" => ["test/a_test.exs:1"],
        "covers" => covers
      }

      {:ok, _, _} =
        ChangeRequests.upload_claims(
          reload(ctx),
          ctx.key,
          claims(front_matter(sha(1), %{"safe_because" => [entry]}))
        )

      refute Enum.any?(rules(ctx), &(elem(&1, 0) == "spec_gap"))

      {:ok, _, _} = ChangeRequests.report_git_facts(reload(ctx), ctx.key, git_facts(sha(2)))

      {:ok, _, _} =
        ChangeRequests.upload_claims(reload(ctx), ctx.key, claims(front_matter(sha(2))))

      assert {"spec_gap", ["exports", "Export is audited", "Audit entry written"]} in rules(ctx)
    end
  end
end
