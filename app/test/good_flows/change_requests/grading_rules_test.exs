defmodule GoodFlows.ChangeRequests.GradingRulesTest do
  use ExUnit.Case, async: true

  import GoodFlows.ChangeRequestFixtures

  alias GoodFlows.ChangeRequests.{Grading, Rules}
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.Glob

  @head sha(1)

  defp policy(sections),
    do:
      ReviewPolicies.compile(
        1,
        Map.merge(%{"format" => "review-policy/1", "paths" => []}, sections)
      )

  # require approved intent, review spec gaps, coverage blocked/needs_review
  defp strict(extra \\ %{}) do
    policy(
      Map.merge(
        %{
          "scenarios" => %{"require_approved_intent" => true, "spec_gaps" => "needs_review"},
          "coverage" => %{"unmapped_areas" => "needs_review", "undriven_features" => "blocked"}
        },
        extra
      )
    )
  end

  defp set(attrs \\ %{}) do
    Map.merge(
      %{
        version: 1,
        digest: "d1",
        approved: true,
        graded: true,
        revision: nil,
        scenarios: [
          %{id: "S1", priority: "must"},
          %{id: "S2", priority: "should"},
          %{id: "S3", priority: "could"}
        ],
        coverage: []
      },
      Map.new(attrs)
    )
  end

  defp run(results, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate(),
        source: "intent",
        digest: "d1",
        finished_at: ~U[2026-11-20 10:00:00.000000Z],
        results: results,
        features: [%{"id" => "lib", "result" => "passed"}]
      },
      Map.new(attrs)
    )
  end

  @passing %{"S1" => "passed", "S2" => "passed", "S3" => "passed"}

  defp index(features),
    do: %{
      version: 3,
      features: Enum.map(features, fn {id, globs} -> {id, Enum.map(globs, &Glob.compile/1)} end)
    }

  defp grading(attrs) do
    Map.merge(
      %{
        linked?: true,
        intent: set(),
        diff: nil,
        runs: [run(@passing)],
        index: index([{"lib", ["lib/**"]}])
      },
      Map.new(attrs)
    )
  end

  defp evaluate(opts) do
    Rules.evaluate(%{
      head: Keyword.get(opts, :head, @head),
      git_facts:
        Keyword.get(opts, :git_facts, %{
          document: git_facts(@head, files: Keyword.get(opts, :files, [file("lib/a.ex")])),
          digest: <<1>>
        }),
      claims: Keyword.get(opts, :claims, %{front_matter: front_matter(@head), digest: <<2>>}),
      workflows: %{},
      policy: Keyword.get(opts, :policy, strict()),
      grading: Keyword.get(opts, :grading, grading([]))
    })
  end

  defp reasons(verdict),
    do: Enum.map(verdict.reasons, &{&1["rule"], &1["outcome"], &1["subject"]})

  test "a fully graded change request is mergeable" do
    verdict = evaluate([])
    assert verdict.state == "mergeable"
    assert [%{"id" => "S1", "result" => "passed"} | _] = verdict.scenarios["intent"]["scenarios"]

    assert verdict.coverage["version"] == 3
  end

  describe "rule table" do
    test "scenario_set_approval: none, unapproved, approval not required" do
      assert {"scenario_set_approval", "pending", []} in reasons(
               evaluate(grading: grading(intent: nil, runs: []))
             )

      unapproved = grading(intent: set(approved: false, graded: false, digest: "d2"))

      assert {"scenario_set_approval", "pending", ["d2"]} in reasons(
               evaluate(grading: unapproved)
             )

      loose = strict(%{"scenarios" => %{"require_approved_intent" => false}})
      graded = grading(intent: set(approved: false, graded: true))

      refute Enum.any?(
               reasons(evaluate(policy: loose, grading: graded)),
               &(elem(&1, 0) == "scenario_set_approval")
             )
    end

    test "scenario_set_missing and diff_only_set" do
      none = grading(linked?: false, intent: nil, runs: [])
      assert {"scenario_set_missing", "pending", []} in reasons(evaluate(grading: none))

      loose = strict(%{"scenarios" => %{"require_approved_intent" => false}})

      assert reasons(evaluate(policy: loose, grading: none))
             |> Enum.filter(&String.starts_with?(elem(&1, 0), "scenario")) == []

      diff = set(digest: "dd", revision: "0000000", graded: true, approved: false)

      only =
        grading(
          linked?: false,
          intent: nil,
          diff: diff,
          runs: [run(@passing, %{source: "diff", digest: "dd"})]
        )

      verdict = evaluate(grading: only)
      assert {"diff_only_set", "needs_review", []} in reasons(verdict)
      refute Enum.any?(reasons(verdict), &(elem(&1, 0) == "scenario_set_missing"))
    end

    test "diff_set_revision when the revision does not name the head" do
      diff = set(digest: "dd", revision: "aaaa123", graded: false, approved: false)
      verdict = evaluate(grading: grading(diff: diff))
      assert {"diff_set_revision", "pending", ["aaaa123"]} in reasons(verdict)
      refute Enum.any?(reasons(verdict), &match?({_, _, ["diff" | _]}, &1))
      assert Grading.names_head?("0000000", @head)
      refute Grading.names_head?("aaaa123", @head)
    end

    test "scenario_results_missing per graded set" do
      assert {"scenario_results_missing", "pending", ["intent"]} in reasons(
               evaluate(grading: grading(runs: []))
             )
    end

    test "must_failed for failed and not_run" do
      verdict = evaluate(grading: grading(runs: [run(%{@passing | "S1" => "not_run"})]))
      assert verdict.state == "blocked"
      assert {"must_failed", "blocked", ["intent", "S1"]} in reasons(verdict)
    end

    test "should_failed, should_not_run, ignore, could" do
      failed = grading(runs: [run(%{@passing | "S2" => "failed", "S3" => "failed"})])

      assert reasons(evaluate(grading: failed))
             |> Enum.filter(&String.starts_with?(elem(&1, 0), "should")) ==
               [{"should_failed", "needs_review", ["intent", "S2"]}]

      not_run = grading(runs: [run(%{@passing | "S2" => "not_run"})])

      assert {"should_not_run", "needs_review", ["intent", "S2"]} in reasons(
               evaluate(grading: not_run)
             )

      ignore =
        strict(%{
          "scenarios" => %{"require_approved_intent" => true, "should_failures" => "ignore"}
        })

      assert evaluate(policy: ignore, grading: failed).state == "mergeable"
    end

    test "spec_gap with subject order; ignore under default" do
      row = %{
        "capability" => "exports",
        "requirement" => "Export is audited",
        "scenario" => "Audit entry written",
        "status" => "no_check",
        "scenarios" => []
      }

      g = grading(intent: set(coverage: [row]))

      assert {"spec_gap", "needs_review", ["exports", "Export is audited", "Audit entry written"]} in reasons(
               evaluate(grading: g)
             )

      default = policy(%{"scenarios" => %{"require_approved_intent" => true}})

      refute Enum.any?(
               reasons(evaluate(policy: default, grading: g)),
               &(elem(&1, 0) == "spec_gap")
             )
    end

    test "unmapped_area and undriven_feature" do
      g = grading(runs: [run(@passing)], index: index([{"checkout", ["lib/checkout/**"]}]))

      verdict =
        evaluate(
          grading: g,
          files: [file("lib/checkout/pay.ex"), file("lib/new.ex"), file("docs/x.md")]
        )

      assert {"unmapped_area", "needs_review", ["lib/new.ex"]} in reasons(verdict)
      assert {"undriven_feature", "blocked", ["checkout"]} in reasons(verdict)
      refute Enum.any?(reasons(verdict), &(elem(&1, 2) == ["docs/x.md"]))

      driven =
        grading(
          runs: [run(@passing, %{features: [%{"id" => "checkout", "result" => "passed"}]})],
          index: g.index
        )

      verdict = evaluate(grading: driven, files: [file("lib/checkout/pay.ex")])
      assert verdict.state == "mergeable"
      assert verdict.coverage["features"] == [%{"id" => "checkout", "driven" => true}]

      failed =
        grading(
          runs: [run(@passing, %{features: [%{"id" => "checkout", "result" => "failed"}]})],
          index: g.index
        )

      assert {"undriven_feature", "blocked", ["checkout"]} in reasons(
               evaluate(grading: failed, files: [file("lib/checkout/pay.ex")])
             )
    end

    test "feature_index_missing replaces both coverage rules; off when both ignore" do
      verdict = evaluate(grading: grading(index: nil))
      assert reasons(verdict) == [{"feature_index_missing", "pending", []}]

      off =
        strict(%{"coverage" => %{"unmapped_areas" => "ignore", "undriven_features" => "ignore"}})

      assert evaluate(policy: off, grading: grading(index: nil)).state == "mergeable"
    end
  end

  test "the same scenario ID in both sets gives two reasons" do
    diff = set(digest: "dd", revision: "000000", graded: true, approved: false)

    runs = [
      run(%{@passing | "S1" => "failed"}),
      run(%{@passing | "S1" => "failed"}, %{source: "diff", digest: "dd"})
    ]

    verdict = evaluate(grading: grading(diff: diff, runs: runs))
    assert {"must_failed", "blocked", ["intent", "S1"]} in reasons(verdict)
    assert {"must_failed", "blocked", ["diff", "S1"]} in reasons(verdict)
  end

  test "pending outranks blocked" do
    g = grading(runs: [run(%{@passing | "S1" => "failed"})], index: nil)
    verdict = evaluate(grading: g)
    assert verdict.state == "pending"

    assert [{"feature_index_missing", "pending", []}, {"must_failed", "blocked", _}] =
             reasons(verdict)
  end

  test "policy version 0 with no set and no index adds no grading reason" do
    v0 = ReviewPolicies.compile(0, ReviewPolicies.Document.default())
    g = %{linked?: true, intent: nil, diff: nil, runs: [], index: nil}
    assert evaluate(policy: v0, grading: g).reasons == []
    assert evaluate(policy: v0, grading: %{g | linked?: false}).reasons == []
  end

  describe "newest counted run per scenario" do
    test "retry after a failure, and a newer not_run" do
      r1 =
        run(%{@passing | "S1" => "failed", "S2" => "passed"}, %{
          finished_at: ~U[2026-11-20 10:00:00.000000Z]
        })

      r2 =
        run(%{@passing | "S1" => "passed", "S2" => "not_run"}, %{
          finished_at: ~U[2026-11-20 10:30:00.000000Z]
        })

      verdict = evaluate(grading: grading(runs: [r2, r1]))
      refute Enum.any?(reasons(verdict), &(elem(&1, 0) == "must_failed"))
      assert {"should_not_run", "needs_review", ["intent", "S2"]} in reasons(verdict)
      assert hd(verdict.scenarios["intent"]["scenarios"])["run_id"] == r2.run_id
      assert Enum.sort(verdict.counted_runs) == Enum.sort([r1.run_id, r2.run_id])
    end

    test "ties break by run_id descending" do
      a = run(%{@passing | "S1" => "failed"}, %{run_id: "00000000-0000-0000-0000-000000000001"})
      b = run(@passing, %{run_id: "00000000-0000-0000-0000-000000000002"})
      assert evaluate(grading: grading(runs: [a, b])).state == "mergeable"
    end
  end

  describe "spec gaps and claims" do
    @row %{
      "capability" => "exports",
      "requirement" => "Export is audited",
      "scenario" => "Audit entry written",
      "status" => "no_check",
      "scenarios" => []
    }
    @covers %{
      "capability" => "exports",
      "requirement" => "Export is audited",
      "scenario" => "Audit entry written"
    }

    defp covering_claims(proof, covers) do
      entry = %{
        "fact" => "Audit row written",
        "location" => "lib/a.ex:1",
        "proof" => proof,
        "covers" => covers
      }

      entry =
        if proof == "ran", do: Map.put(entry, "evidence", ["test/a_test.exs:1"]), else: entry

      %{front_matter: front_matter(@head, %{"safe_because" => [entry]}), digest: <<2>>}
    end

    defp gap_reasons(claims) do
      evaluate(grading: grading(intent: set(coverage: [@row])), claims: claims) |> reasons()
    end

    test "covered at the minimum closes the gap" do
      refute Enum.any?(gap_reasons(covering_claims("ran", @covers)), &(elem(&1, 0) == "spec_gap"))
    end

    test "covered below the minimum keeps the gap and fires proof_below_minimum" do
      r = gap_reasons(covering_claims("walked", @covers))

      assert {"spec_gap", "needs_review", ["exports", "Export is audited", "Audit entry written"]} in r

      assert {"proof_below_minimum", "needs_review", ["Audit row written"]} in r
    end

    test "covers another scenario" do
      r = gap_reasons(covering_claims("ran", %{@covers | "scenario" => "Audit entry removed"}))
      assert Enum.any?(r, &(elem(&1, 0) == "spec_gap"))
    end

    test "no claims: claims_missing, no spec_gap yet" do
      r = evaluate(grading: grading(intent: set(coverage: [@row])), claims: nil) |> reasons()
      assert {"claims_missing", "pending", [@head]} in r
      refute Enum.any?(r, &(elem(&1, 0) == "spec_gap"))
    end
  end

  describe "before Git facts" do
    test "an unapproved intent set gives exactly two reasons" do
      g = grading(intent: set(approved: false, graded: false), runs: [])
      verdict = evaluate(head: nil, git_facts: nil, claims: nil, grading: g)
      assert verdict.head == nil

      assert reasons(verdict) == [
               {"git_facts_missing", "pending", []},
               {"scenario_set_approval", "pending", ["d1"]}
             ]
    end

    test "an approved intent set gives only git_facts_missing" do
      verdict =
        evaluate(head: nil, git_facts: nil, claims: nil, grading: grading(runs: [], index: nil))

      assert reasons(verdict) == [{"git_facts_missing", "pending", []}]
    end
  end

  describe "counts?" do
    @ignore Enum.map(["docs/**", "**/*.md"], &Glob.compile/1)

    defp commit(n, files),
      do: %{
        "sha" => sha(n),
        "parents" => [sha(n - 1)],
        "changed_files" => Enum.map(files, &file/1)
      }

    test "a later rename out of code into docs is a code change" do
      renamed = %{
        "sha" => sha(11),
        "parents" => [sha(10)],
        "changed_files" => [file("docs/x.md", %{"status" => "renamed", "old_path" => "app/x.ex"})]
      }

      refute Grading.counts?(sha(10), sha(11), [commit(10, ["lib/a.ex"]), renamed], @ignore)
    end

    test "head, docs-only later commit, code later commit, missing commit" do
      commits = [
        commit(10, ["lib/a.ex"]),
        commit(11, ["docs/usage.md", "README.md"]),
        commit(12, ["app/lib/good_flows/caches.ex"])
      ]

      assert Grading.counts?(sha(12), sha(12), commits, @ignore)
      assert Grading.counts?(sha(10), sha(11), Enum.take(commits, 2), @ignore)
      refute Grading.counts?(sha(10), sha(12), commits, @ignore)
      refute Grading.counts?(sha(11), sha(12), commits, @ignore)
      refute Grading.counts?(sha(99), sha(12), commits, @ignore)
    end
  end
end
