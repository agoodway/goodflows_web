defmodule GoodFlows.ChangeRequests.RulesTest do
  use ExUnit.Case, async: true

  import GoodFlows.ChangeRequestFixtures

  alias GoodFlows.ChangeRequests.Rules
  alias GoodFlows.ReviewPolicies

  @head sha(1)

  defp policy(sections \\ %{}, version \\ 1),
    do:
      ReviewPolicies.compile(
        version,
        Map.merge(%{"format" => "review-policy/1", "paths" => []}, sections)
      )

  defp inputs(opts) do
    files = Keyword.get(opts, :files, [file("lib/a.ex")])
    claims = Keyword.get(opts, :claims, front_matter(@head))

    %{
      head: Keyword.get(opts, :head, @head),
      git_facts:
        Keyword.get(opts, :git_facts, %{document: git_facts(@head, files: files), digest: <<1>>}),
      claims: claims && %{front_matter: claims, digest: <<2>>},
      workflows: Keyword.get(opts, :workflows, %{}),
      policy: Keyword.get(opts, :policy, policy())
    }
  end

  defp evaluate(opts), do: Rules.evaluate(inputs(opts))
  defp rules(verdict), do: Enum.map(verdict.reasons, & &1["rule"])

  defp claims_with(overrides), do: front_matter(@head, overrides)

  test "nothing fired is mergeable with the head and policy version" do
    assert %{state: "mergeable", reasons: [], head: @head, policy_version: 4} =
             evaluate(policy: policy(%{}, 4))
  end

  test "no head: one git_facts_missing with an empty subject and a null head" do
    verdict =
      evaluate(
        head: nil,
        git_facts: nil,
        claims: nil,
        policy: policy(%{"evidence" => %{"required_workflows" => ["ci"]}})
      )

    assert %{
             state: "pending",
             head: nil,
             reasons: [%{"rule" => "git_facts_missing", "subject" => []}]
           } =
             verdict
  end

  test "facts only for another target: git_facts_missing names the head, which is kept" do
    verdict = evaluate(git_facts: nil, claims: nil)
    assert %{state: "pending", head: @head} = verdict
    assert [%{"rule" => "git_facts_missing", "subject" => [@head]}] = verdict.reasons
  end

  test "facts without claims: claims_missing and no claims rules" do
    verdict =
      evaluate(
        claims: nil,
        policy: policy(%{"size" => %{"max_changed_files" => 1}}),
        files: [file("a"), file("b")]
      )

    assert verdict.state == "pending"
    assert rules(verdict) == ["claims_missing", "max_changed_files"]
    assert hd(verdict.reasons)["subject"] == [@head]
  end

  test "pending outranks blocked, which outranks needs_review; reasons are sorted" do
    verdict =
      evaluate(
        claims: claims_with(%{"door" => "one_way"}),
        workflows: %{"ci" => %{outcome: "failed", run_id: "r1"}, "e2e" => nil},
        policy: policy(%{"evidence" => %{"required_workflows" => ["e2e", "ci"]}})
      )

    assert verdict.state == "pending"

    assert rules(verdict) == [
             "required_workflow_missing",
             "required_workflow_failed",
             "one_way_door"
           ]

    assert Enum.map(verdict.reasons, & &1["subject"]) == [["e2e"], ["ci"], []]

    blocked =
      evaluate(
        claims: claims_with(%{"door" => "one_way"}),
        workflows: %{"ci" => %{outcome: "failed", run_id: "r1"}},
        policy: policy(%{"evidence" => %{"required_workflows" => ["ci"]}})
      )

    assert blocked.state == "blocked"
    assert "one_way_door" in rules(blocked)
  end

  test "required workflows: passed, cancelled, missing and none required" do
    required = policy(%{"evidence" => %{"required_workflows" => ["ci"]}})

    assert evaluate(policy: required, workflows: %{"ci" => %{outcome: "passed", run_id: "r"}}).reasons ==
             []

    assert [%{"rule" => "required_workflow_missing"}] =
             evaluate(
               policy: required,
               workflows: %{"ci" => %{outcome: "cancelled", run_id: "r"}}
             ).reasons

    assert [%{"rule" => "required_workflow_missing", "subject" => ["ci"]}] =
             evaluate(policy: required, workflows: %{"ci" => nil}).reasons

    assert evaluate(workflows: %{}).reasons == []
  end

  test "one_way_door follows the setting" do
    one_way = claims_with(%{"door" => "one_way"})

    for {setting, expected} <- [
          {"needs_review", "needs_review"},
          {"blocked", "blocked"},
          {"ignore", nil}
        ] do
      verdict =
        evaluate(claims: one_way, policy: policy(%{"claims" => %{"one_way_door" => setting}}))

      assert Enum.map(verdict.reasons, & &1["outcome"]) == List.wrap(expected), setting
    end

    assert evaluate(claims: claims_with(%{"door" => "two_way"})).reasons == []
  end

  test "proof_below_minimum lists the facts below the minimum" do
    entry = %{"fact" => "Cache keys are per project", "location" => "l", "proof" => "pointed"}

    claims =
      claims_with(%{
        "safe_because" => [entry, %{entry | "fact" => "Walked", "proof" => "walked"}]
      })

    assert [
             %{
               "rule" => "proof_below_minimum",
               "outcome" => "needs_review",
               "subject" => ["Cache keys are per project", "Walked"]
             }
           ] =
             evaluate(claims: claims).reasons

    assert [%{"subject" => ["Cache keys are per project"]}] =
             evaluate(
               claims: claims,
               policy: policy(%{"claims" => %{"min_proof_level" => "walked"}})
             ).reasons

    assert evaluate(
             claims: claims,
             policy: policy(%{"claims" => %{"min_proof_level" => "stated"}})
           ).reasons == []
  end

  test "open_items lists risks and question ids and follows the setting" do
    question = %{"id" => "q1", "text" => "t", "options" => ["a"], "recommendation" => "a"}
    risk = %{"risk" => "Slow query", "location" => "l", "affected" => "a"}
    claims = claims_with(%{"questions" => [question], "left_open" => [risk]})

    assert [
             %{
               "rule" => "open_items",
               "outcome" => "needs_review",
               "subject" => ["Slow query", "q1"]
             }
           ] =
             evaluate(claims: claims).reasons

    assert [%{"outcome" => "blocked"}] =
             evaluate(claims: claims, policy: policy(%{"claims" => %{"open_items" => "blocked"}})).reasons

    assert evaluate(claims: claims, policy: policy(%{"claims" => %{"open_items" => "ignore"}})).reasons ==
             []

    assert evaluate(claims: claims_with(%{"questions" => [], "left_open" => []})).reasons == []
  end

  test "path_match: one reason per entry, glob first then sorted paths, ignore adds none" do
    paths = [
      %{"glob" => "app/priv/**", "outcome" => "needs_review"},
      %{"glob" => "app/priv/repo/**", "outcome" => "needs_review"},
      %{"glob" => "docs/**", "outcome" => "ignore"},
      %{"glob" => ".github/workflows/*", "outcome" => "blocked"}
    ]

    files = [file("app/priv/repo/b.exs"), file("app/priv/repo/a.exs"), file("docs/x.md")]
    verdict = evaluate(files: files, policy: policy(%{"paths" => paths}))

    assert Enum.map(verdict.reasons, & &1["subject"]) == [
             ["app/priv/**", "app/priv/repo/a.exs", "app/priv/repo/b.exs"],
             ["app/priv/repo/**", "app/priv/repo/a.exs", "app/priv/repo/b.exs"]
           ]

    assert hd(verdict.reasons)["message"] =~ "app/priv/**"

    blocked =
      evaluate(files: [file(".github/workflows/ci.yml")], policy: policy(%{"paths" => paths}))

    assert blocked.state == "blocked"
  end

  test "path_match sees a rename out of a sensitive directory" do
    paths = [%{"glob" => "app/priv/repo/migrations/**", "outcome" => "needs_review"}]

    renamed =
      file("app/priv/a.exs", status: "renamed", old_path: "app/priv/repo/migrations/a.exs")

    assert [
             %{
               "rule" => "path_match",
               "subject" => ["app/priv/repo/migrations/**", "app/priv/repo/migrations/a.exs"]
             }
           ] =
             evaluate(files: [renamed], policy: policy(%{"paths" => paths})).reasons
  end

  test "size limits fire only above the limit" do
    size = policy(%{"size" => %{"max_changed_files" => 2, "max_changed_lines" => 1500}})

    assert evaluate(
             files: [file("a", additions: 1000, deletions: 500), file("b", additions: 0)],
             policy: size
           ).reasons == []

    over =
      evaluate(
        files: [file("a", additions: 1000, deletions: 501), file("b"), file("c")],
        policy: size
      )

    assert rules(over) == ["max_changed_files", "max_changed_lines"]
    assert Enum.all?(over.reasons, &(&1["subject"] == [] and &1["outcome"] == "needs_review"))
  end

  test "the same inputs give the same verdict, and rule plus subject is unique" do
    opts = [
      claims: claims_with(%{"door" => "one_way"}),
      files: [file("app/priv/repo/a.exs")],
      policy:
        policy(%{
          "paths" => [
            %{"glob" => "app/**", "outcome" => "needs_review"},
            %{"glob" => "app/priv/**", "outcome" => "blocked"}
          ]
        })
    ]

    first = evaluate(opts)
    assert first == evaluate(opts)
    keys = Enum.map(first.reasons, &{&1["rule"], &1["subject"]})
    assert keys == Enum.uniq(keys)
    assert first.inputs["git_facts"] == "01"
    assert first.inputs["claims"] == "02"
  end

  test "a Must without a result in the merge-result run is merge_result_failed as not_run" do
    set = %{
      version: 1,
      digest: "d1",
      approved: true,
      graded: true,
      revision: nil,
      scenarios: [%{id: "S1", priority: "must"}, %{id: "S2", priority: "must"}],
      coverage: []
    }

    run = fn run_id, results ->
      %{
        id: Ecto.UUID.generate(),
        run_id: run_id,
        source: "intent",
        digest: "d1",
        finished_at: ~U[2026-11-20 10:00:00Z],
        results: results,
        features: []
      }
    end

    verdict =
      Rules.evaluate(
        Map.merge(inputs([]), %{
          grading: %{
            linked?: true,
            intent: set,
            diff: nil,
            runs: [run.("head", %{"S1" => "passed", "S2" => "passed"})],
            index: nil
          },
          merge_result: %{base: sha(9), runs: [run.("mr", %{"S2" => "passed"})]}
        })
      )

    assert [%{"subject" => ["intent", "S1"], "outcome" => "blocked", "message" => message}] =
             Enum.filter(verdict.reasons, &(&1["rule"] == "merge_result_failed"))

    assert message == "Must scenario S1 of the intent set is not_run on the merge result"
  end

  test "inactive settings do not change the verdict" do
    opts = [claims: claims_with(%{"door" => "one_way"})]
    base = evaluate(opts)

    other =
      evaluate(
        opts ++
          [
            policy:
              policy(%{
                "merge" => %{"lease_ttl" => "1h", "regrade_merge_result" => false}
              })
          ]
      )

    assert {other.state, other.reasons} == {base.state, base.reasons}
  end

  describe "dependency_not_merged" do
    defp with_dependencies(dependencies, opts \\ []),
      do: opts |> inputs() |> Map.put(:dependencies, dependencies) |> Rules.evaluate()

    defp dependency(id, linking),
      do: %{
        change_id: id,
        change_requests: for({n, state} <- linking, do: %{number: n, state: state})
      }

    test "an open linking change request: pending, subject the id, message names it" do
      verdict = with_dependencies([dependency("add-login", [{40, "closed"}, {41, "open"}])])

      assert %{state: "pending", reasons: [reason]} = verdict
      assert %{"rule" => "dependency_not_merged", "subject" => ["add-login"]} = reason
      assert reason["message"] =~ "change request 41 links it"
      refute reason["message"] =~ "40"
      assert reason["message"] =~ "rebase onto a commit where add-login is archived"
    end

    test "several draft or open linking change requests are all named" do
      [reason] =
        with_dependencies([dependency("add-login", [{41, "draft"}, {45, "open"}])]).reasons

      assert reason["message"] =~ "change requests 41, 45 link it"
    end

    test "every linking change request closed" do
      [reason] =
        with_dependencies([dependency("add-login", [{40, "closed"}, {41, "closed"}])]).reasons

      assert reason["subject"] == ["add-login"]

      assert reason["message"] =~
               "Every change request linking change add-login is closed (40, 41)"

      assert reason["message"] =~ "rebase onto a commit where add-login is archived"
    end

    test "no linking change request" do
      [reason] = with_dependencies([dependency("add-login", [])]).reasons
      assert reason["message"] =~ "No change request links change add-login"
      assert reason["message"] =~ "rebase onto a commit where add-login is archived"
    end

    test "one merged linking change request satisfies it, whatever the others" do
      verdict =
        with_dependencies([
          dependency("add-login", [{40, "closed"}, {41, "merged"}, {42, "open"}])
        ])

      assert %{state: "mergeable", reasons: []} = verdict
      assert verdict.inputs["dependencies"] == ["add-login"]
    end

    test "one reason per unmerged id; inputs list every id in stored order" do
      verdict =
        with_dependencies([
          dependency("b-sessions", []),
          dependency("add-login", [{41, "merged"}]),
          dependency("a-tokens", [{43, "open"}])
        ])

      assert Enum.map(verdict.reasons, & &1["subject"]) == [["a-tokens"], ["b-sessions"]]
      assert verdict.inputs["dependencies"] == ["b-sessions", "add-login", "a-tokens"]
    end

    test "fires without Git facts, next to git_facts_missing" do
      verdict =
        with_dependencies([dependency("add-login", [])], git_facts: nil, claims: nil)

      assert rules(verdict) == ["dependency_not_merged", "git_facts_missing"]
    end

    test "no dependencies: nothing fires and inputs record an empty list" do
      verdict = with_dependencies([])
      assert verdict.reasons == []
      assert verdict.inputs["dependencies"] == []
    end
  end
end
