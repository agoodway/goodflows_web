defmodule GoodFlows.ChangeRequests.IterationHistoryTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, GitFacts, ReasonSpan, Verdict, VerdictTransition}
  alias GoodFlows.ProjectEvents
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Review
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ScenarioSets
  alias GoodFlows.VerifyRuns
  alias GoodFlows.WorkflowRuns

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "IH #{System.unique_integer()}"})
    account_user = Accounts.get_account_user(user, account)
    {api_key, _token} = api_key_fixture(account_user, %{type: :private})
    project = project_fixture(account, %{default_branch: "main"})
    %{account: account, account_user: account_user, api_key: api_key, project: project}
  end

  defp create!(ctx, attrs \\ %{}) do
    body = Map.merge(%{"title" => "Add login", "source_branch" => "feat/login"}, attrs)
    {:ok, cr} = ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, body)
    cr
  end

  defp doc(head, oldest_first_sha_paths, merge_base \\ sha(0)) do
    shas = Enum.map(oldest_first_sha_paths, &elem(&1, 0))

    %{
      "format" => "git-facts/1",
      "head" => head,
      "target" => %{"branch" => "main", "merge_base" => merge_base},
      "commits" =>
        oldest_first_sha_paths
        |> Enum.zip([merge_base | shas])
        |> Enum.map(fn {{sha, paths}, parent} ->
          %{"sha" => sha, "parents" => [parent], "changed_files" => Enum.map(paths, &file/1)}
        end),
      "diff" => %{
        "files" =>
          oldest_first_sha_paths
          |> Enum.flat_map(&elem(&1, 1))
          |> Enum.uniq()
          |> Enum.map(&file/1)
      }
    }
  end

  defp report!(cr, ctx, document) do
    {:ok, _status, cr} = ChangeRequests.report_git_facts(reload(cr), ctx.api_key, document)
    cr
  end

  defp claims!(cr, ctx, head, overrides \\ %{}) do
    {:ok, _status, cr} =
      ChangeRequests.upload_claims(reload(cr), ctx.api_key, claims(front_matter(head, overrides)))

    cr
  end

  defp policy!(ctx, sections, previous) do
    body = %{
      "previous_version" => previous,
      "policy" => Map.merge(%{"format" => "review-policy/1", "paths" => []}, sections)
    }

    {:ok, :created, version} =
      ReviewPolicies.write(ctx.project, ctx.account_user, ctx.api_key, body)

    version
  end

  defp ci!(ctx, commit, outcome, at \\ "2026-11-05T12:00:00Z") do
    {:ok, _} =
      WorkflowRuns.ingest(
        ctx.account,
        ctx.project,
        ctx.api_key,
        run_document(commit, outcome, started_at: at)
      )

    :ok
  end

  defp merge!(ctx, cr, commit \\ sha(0xC1)) do
    {:ok, merged} =
      ChangeRequests.report_merge(reload(cr), ctx.api_key, %{
        "merged_commit" => commit,
        "target_branch" => "main"
      })

    merged
  end

  defp reload(cr), do: Repo.get!(ChangeRequest, cr.id)
  defp state(cr), do: Repo.get!(Verdict, cr.id).state

  defp kind(cr, head),
    do:
      Repo.one!(
        from f in GitFacts,
          where: f.change_request_id == ^cr.id and f.head == ^head,
          select: {f.previous_head, f.head_kind}
      )

  defp transitions(cr),
    do:
      Repo.all(
        from t in VerdictTransition,
          where: t.change_request_id == ^cr.id,
          order_by: t.inserted_at
      )

  defp spans(cr, rule),
    do:
      Repo.all(
        from s in ReasonSpan,
          where: s.change_request_id == ^cr.id and s.rule == ^rule,
          order_by: s.opened_at
      )

  defp open_spans(cr),
    do:
      Repo.all(from s in ReasonSpan, where: s.change_request_id == ^cr.id and is_nil(s.closed_at))

  describe "head kinds" do
    test "first, fast_forward, target_merged and retarget", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      assert kind(cr, sha(1)) == {nil, "first"}

      cr = report!(cr, ctx, doc(sha(2), [{sha(1), ["a.ex"]}, {sha(2), ["b.ex"]}]))
      assert kind(cr, sha(2)) == {sha(1), "fast_forward"}

      cr =
        report!(
          cr,
          ctx,
          doc(sha(3), [{sha(1), ["a.ex"]}, {sha(2), ["b.ex"]}, {sha(3), []}], sha(9))
        )

      assert kind(cr, sha(3)) == {sha(2), "target_merged"}

      cr = cr |> Ecto.Changeset.change(target_branch: "release") |> Repo.update!()

      _ =
        report!(cr, ctx, %{
          doc(sha(3), [{sha(3), ["a.ex"]}], sha(9))
          | "target" => %{"branch" => "release", "merge_base" => sha(9)}
        })

      assert {sha(3), "retarget"} ==
               Repo.one!(
                 from f in GitFacts,
                   where: f.change_request_id == ^cr.id and f.target_branch == "release",
                   select: {f.previous_head, f.head_kind}
               )
    end

    test "rebase, rewrite and rewrite without stored facts for the previous head", ctx do
      commits = [{sha(1), ["a.ex"]}, {sha(2), ["b.ex"]}]
      cr = ctx |> create!() |> report!(ctx, doc(sha(2), commits, sha(10)))

      cr = report!(cr, ctx, doc(sha(4), [{sha(3), ["a.ex"]}, {sha(4), ["b.ex"]}], sha(11)))
      assert kind(cr, sha(4)) == {sha(2), "rebase"}

      cr = report!(cr, ctx, doc(sha(5), [{sha(3), ["a.ex"]}, {sha(5), ["b.ex"]}], sha(11)))
      assert kind(cr, sha(5)) == {sha(4), "rewrite"}

      cr = report!(cr, ctx, doc(sha(6), [{sha(6), ["a.ex", "b.ex"]}], sha(12)))
      assert kind(cr, sha(6)) == {sha(5), "rewrite"}

      cr = cr |> Ecto.Changeset.change(head: sha(7)) |> Repo.update!()
      _ = report!(cr, ctx, doc(sha(8), [{sha(8), ["a.ex"]}], sha(13)))
      assert kind(cr, sha(8)) == {sha(7), "rewrite"}
    end

    test "a head that keeps a previous head without stored facts is a fast_forward", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      cr = cr |> Ecto.Changeset.change(head: sha(7)) |> Repo.update!()
      _ = report!(cr, ctx, doc(sha(8), [{sha(7), ["a.ex"]}, {sha(8), ["b.ex"]}], sha(13)))
      assert kind(cr, sha(8)) == {sha(7), "fast_forward"}
    end

    test "an exact retry of an earlier head keeps its kind and responds retry", ctx do
      first = doc(sha(1), [{sha(1), ["a.ex"]}])
      cr = ctx |> create!() |> report!(ctx, first)
      cr = report!(cr, ctx, doc(sha(2), [{sha(2), ["a.ex"]}]))

      assert {:ok, :retry, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, first)
      assert cr.head == sha(1)
      assert kind(cr, sha(1)) == {nil, "first"}

      assert %VerdictTransition{cause: "head", head_kind: nil, to_head: to_head} =
               List.last(transitions(cr))

      assert to_head == sha(1)
    end
  end

  describe "verdict transitions" do
    setup ctx do
      _ = policy!(ctx, %{"evidence" => %{"required_workflows" => ["ci"]}}, 0)
      :ok
    end

    test "created, inputs, head with its kind, and none when nothing changed", ctx do
      cr = create!(ctx)

      assert [%{cause: "created", from_state: nil, from_head: nil, to_state: "pending"}] =
               transitions(cr)

      cr = cr |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}])) |> claims!(ctx, sha(1))
      count = length(transitions(cr))

      ci!(ctx, sha(1), "failed")
      assert state(cr) == "blocked"

      assert %{cause: "inputs", from_state: "pending", to_state: "blocked", head_kind: nil} =
               List.last(transitions(cr))

      assert length(transitions(cr)) == count + 1

      ChangeRequests.recompute(reload(cr))
      assert length(transitions(cr)) == count + 1

      cr = report!(cr, ctx, doc(sha(2), [{sha(1), ["a.ex"]}, {sha(2), ["a.ex"]}]))
      assert state(cr) == "pending"

      assert %{
               from_state: "blocked",
               to_state: "pending",
               from_head: from_head,
               to_head: to_head,
               cause: "head",
               head_kind: "fast_forward"
             } = List.last(transitions(cr))

      assert {from_head, to_head} == {sha(1), sha(2)}
    end

    test "a policy change records cause policy without a head kind", ctx do
      cr =
        ctx
        |> create!()
        |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
        |> claims!(ctx, sha(1), %{"door" => "one_way"})

      {:ok, cr} = ChangeRequests.transition(cr, ctx.api_key, :ready)
      ci!(ctx, sha(1), "passed")
      assert state(cr) == "needs_review"

      _ =
        policy!(
          ctx,
          %{
            "evidence" => %{"required_workflows" => ["ci"]},
            "claims" => %{"one_way_door" => "ignore"}
          },
          1
        )

      assert state(cr) == "mergeable"

      assert %{cause: "policy", head_kind: nil, policy_version: 2, from_state: "needs_review"} =
               List.last(transitions(cr))
    end

    test "draft records transitions; closed and merged ones none", ctx do
      draft = create!(ctx)
      assert [%{cause: "created"}] = transitions(draft)

      closed = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      {:ok, closed} = ChangeRequests.transition(closed, ctx.api_key, :close)
      merged = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      merged = merge!(ctx, merged)
      before = {transitions(closed), transitions(merged)}

      assert ChangeRequests.recompute(closed) == :skipped
      assert ChangeRequests.recompute(merged) == :skipped
      ci!(ctx, sha(1), "passed")
      _ = policy!(ctx, %{}, 1)

      assert {transitions(closed), transitions(merged)} == before
    end

    test "transitions outlive the project event sweep", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      kept = transitions(cr)
      assert length(kept) == 2

      assert Repo.exists?(
               from e in Event,
                 where: e.project_id == ^ctx.project.id and e.type == "verdict_changed"
             )

      assert ProjectEvents.sweep(DateTime.add(DateTime.utc_now(), 91, :day)) >= 2

      refute Repo.exists?(
               from e in Event,
                 where: e.project_id == ^ctx.project.id and e.type == "verdict_changed"
             )

      assert transitions(cr) == kept
    end
  end

  describe "reason spans" do
    test "a head change closes with head and the kind; unchanged reasons change nothing",
         ctx do
      _ = policy!(ctx, %{"evidence" => %{"required_workflows" => ["ci"]}}, 0)
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      cr = claims!(cr, ctx, sha(1))
      ci!(ctx, sha(1), "failed")
      assert [%{closed_at: nil} = failed] = spans(cr, "required_workflow_failed")
      assert failed.opened_head == sha(1)

      before = Repo.all(from s in ReasonSpan, where: s.change_request_id == ^cr.id)
      ChangeRequests.recompute(reload(cr))
      assert Repo.all(from s in ReasonSpan, where: s.change_request_id == ^cr.id) == before

      cr = report!(cr, ctx, doc(sha(2), [{sha(1), ["a.ex"]}, {sha(2), ["a.ex"]}]))

      assert [
               %{
                 closed_head: closed_head,
                 close_cause: "head",
                 close_head_kind: "fast_forward"
               }
             ] = spans(cr, "required_workflow_failed")

      assert closed_head == sha(2)

      assert [%{close_cause: "inputs"}, %{closed_at: nil, inherited: false}] =
               spans(cr, "required_workflow_missing")
    end

    test "an outcome changed by policy closes with policy and opens the new outcome", ctx do
      paths = fn outcome -> [%{"glob" => "lib/**", "outcome" => outcome}] end
      _ = policy!(ctx, %{"paths" => paths.("needs_review")}, 0)
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["lib/a.ex"]}]))
      _ = claims!(cr, ctx, sha(1))

      _ = policy!(ctx, %{"paths" => paths.("blocked")}, 1)

      assert [
               %{outcome: "needs_review", close_cause: "policy", close_head_kind: nil} = old,
               %{outcome: "blocked", closed_at: nil, opened_policy_version: 2} = new
             ] = spans(cr, "path_match")

      assert old.subject == new.subject
      assert old.subject == ["lib/**", "lib/a.ex"]
    end

    test "an approved reason stays open; merge closes it with merged; a retry changes nothing",
         ctx do
      cr =
        ctx
        |> create!()
        |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
        |> claims!(ctx, sha(1), %{"door" => "one_way"})

      [item] = Review.packet(cr).items
      actor = Review.cli_actor(ctx.account_user, ctx.api_key)
      {:ok, _} = Review.answer(cr, actor, item.id, %{"head" => sha(1), "answer" => "approve"})
      assert state(cr) == "mergeable"
      assert [%{closed_at: nil}] = spans(cr, "one_way_door")

      merged = merge!(ctx, cr)

      assert [%{close_cause: "merged", closed_head: head, closed_at: closed_at}] =
               spans(cr, "one_way_door")

      assert head == sha(1)
      assert closed_at == merged.merged_at
      assert open_spans(cr) == []

      all = Repo.all(from s in ReasonSpan, where: s.change_request_id == ^cr.id)
      _ = merge!(ctx, merged)
      assert Repo.all(from s in ReasonSpan, where: s.change_request_id == ^cr.id) == all
    end

    test "a close closes every span with closed and a reopen opens new ones", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      assert [%{closed_at: nil}] = spans(cr, "claims_missing")

      {:ok, closed} = ChangeRequests.transition(cr, ctx.api_key, :close)
      assert [%{close_cause: "closed", closed_head: head}] = spans(cr, "claims_missing")
      assert head == sha(1)
      assert open_spans(cr) == []

      {:ok, _} = ChangeRequests.transition(closed, ctx.api_key, :reopen)

      assert [%{close_cause: "closed"}, %{closed_at: nil, inherited: false}] =
               spans(cr, "claims_missing")
    end

    test "a workflow run on an open change request without spans opens inherited spans",
         ctx do
      _ = policy!(ctx, %{"evidence" => %{"required_workflows" => ["ci"]}}, 0)
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      {:ok, cr} = ChangeRequests.transition(cr, ctx.api_key, :ready)
      Repo.delete_all(from s in ReasonSpan, where: s.change_request_id == ^cr.id)

      ci!(ctx, sha(1), "failed")

      assert [%{inherited: true, closed_at: nil}] = spans(cr, "claims_missing")
      assert [%{inherited: false, closed_at: nil}] = spans(cr, "required_workflow_failed")
      assert spans(cr, "required_workflow_missing") == []
    end
  end

  describe "reason spans and verify runs" do
    setup ctx do
      _ = policy!(ctx, %{"scenarios" => %{"require_approved_intent" => true}}, 0)
      cr = create!(ctx, %{"openspec_change" => "add-export"})
      fm = intent_fm("add-export", [scenario("S1"), scenario("S2")])
      {:ok, _, version} = ScenarioSets.upload(cr, ctx.api_key, set_body(fm))

      {:ok, :created, _} =
        ScenarioSets.decide(reload(cr), ctx.account_user, ctx.api_key, :approve, %{
          "digest" => version.digest
        })

      cr = cr |> report!(ctx, doc(sha(1), [{sha(1), ["lib/a.ex"]}])) |> claims!(ctx, sha(1))
      %{cr: cr, digest: version.digest}
    end

    defp verify!(ctx, results, finished_at) do
      doc = run_doc(ctx.digest, "intent", sha(1), results, finished_at: finished_at)
      {:ok, _} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.api_key, doc)
      :ok
    end

    test "a verify run that clears one of two must_failed reasons closes only its span", ctx do
      verify!(ctx, [result("S1", "failed"), result("S2", "failed")], "2026-11-20T10:00:00Z")
      assert state(ctx.cr) == "blocked"
      assert [_, _] = spans(ctx.cr, "must_failed")
      count = length(transitions(ctx.cr))

      verify!(ctx, [result("S1"), result("S2", "failed")], "2026-11-20T11:00:00Z")
      assert state(ctx.cr) == "blocked"

      by_subject = Map.new(spans(ctx.cr, "must_failed"), &{&1.subject, &1})

      assert %{close_cause: "inputs", closed_head: head} = by_subject[["intent", "S1"]]
      assert head == sha(1)
      assert %{closed_at: nil} = by_subject[["intent", "S2"]]
      assert length(transitions(ctx.cr)) == count
    end
  end

  describe "merge counts" do
    setup ctx do
      _ = policy!(ctx, %{"evidence" => %{"required_workflows" => ["ci"]}}, 0)
      :ok
    end

    test "two fixes after a block", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      cr = claims!(cr, ctx, sha(1))
      ci!(ctx, sha(1), "failed")
      assert state(cr) == "blocked"

      cr = report!(cr, ctx, doc(sha(2), [{sha(1), ["a.ex"]}, {sha(2), ["a.ex"]}]))
      cr = claims!(cr, ctx, sha(2), %{"door" => "one_way"})
      ci!(ctx, sha(2), "passed")
      assert state(cr) == "needs_review"

      cr = report!(cr, ctx, doc(sha(3), [{sha(4), ["a.ex"]}, {sha(3), ["a.ex"]}]))
      assert kind(cr, sha(3)) == {sha(2), "rewrite"}
      cr = claims!(cr, ctx, sha(3))
      ci!(ctx, sha(3), "passed")
      assert state(cr) == "mergeable"

      merged = merge!(ctx, cr)
      assert {merged.merged_head_count, merged.merged_fix_iterations} == {3, 2}
    end

    test "a rebase after a block is not a fix", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      cr = claims!(cr, ctx, sha(1))
      ci!(ctx, sha(1), "failed")
      assert state(cr) == "blocked"

      cr = report!(cr, ctx, doc(sha(2), [{sha(2), ["a.ex"]}], sha(9)))
      assert kind(cr, sha(2)) == {sha(1), "rebase"}

      merged = merge!(ctx, cr)
      assert {merged.merged_head_count, merged.merged_fix_iterations} == {2, 0}
    end

    test "a new head before any grade is not a fix", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      cr = report!(cr, ctx, doc(sha(2), [{sha(1), ["a.ex"]}, {sha(2), ["a.ex"]}]))

      assert Enum.all?(transitions(cr), &(&1.to_state == "pending"))
      merged = merge!(ctx, cr)
      assert {merged.merged_head_count, merged.merged_fix_iterations} == {2, 0}
    end

    test "no Git facts count zero; a pre-change Git facts row gives null", ctx do
      merged = merge!(ctx, create!(ctx))
      assert {merged.merged_head_count, merged.merged_fix_iterations} == {0, 0}

      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      cr = report!(cr, ctx, doc(sha(2), [{sha(1), ["a.ex"]}, {sha(2), ["a.ex"]}]))

      Repo.update_all(
        from(f in GitFacts, where: f.change_request_id == ^cr.id and f.head == ^sha(1)),
        set: [head_kind: nil, previous_head: nil]
      )

      merged = merge!(ctx, cr)
      assert {merged.merged_head_count, merged.merged_fix_iterations} == {2, nil}
    end

    test "a retarget at the same head counts one head", ctx do
      cr = ctx |> create!(%{"target_branch" => "a"})

      cr =
        report!(cr, ctx, %{
          doc(sha(1), [{sha(1), ["a.ex"]}])
          | "target" => %{"branch" => "a", "merge_base" => sha(0)}
        })

      cr = cr |> Ecto.Changeset.change(target_branch: "main") |> Repo.update!()
      cr = report!(cr, ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))

      assert Repo.aggregate(from(f in GitFacts, where: f.change_request_id == ^cr.id), :count) ==
               2

      merged = merge!(ctx, cr)
      assert {merged.merged_head_count, merged.merged_fix_iterations} == {1, 0}
    end

    test "a retried merge report returns the stored counts unchanged", ctx do
      cr = ctx |> create!() |> report!(ctx, doc(sha(1), [{sha(1), ["a.ex"]}]))
      merged = merge!(ctx, cr)
      _ = report!(create!(ctx), ctx, doc(sha(2), [{sha(2), ["a.ex"]}]))

      Repo.insert!(%GitFacts{
        change_request_id: cr.id,
        head: sha(3),
        target_branch: "main",
        document: doc(sha(3), [{sha(3), ["a.ex"]}]),
        digest: <<0>>
      })

      again = merge!(ctx, merged)
      assert {again.merged_head_count, again.merged_fix_iterations} == {1, 0}
    end
  end
end
