defmodule GoodFlows.ChangeRequestsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, Event, GitFacts}
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.Document
  alias GoodFlows.WorkflowRuns

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "CR #{System.unique_integer()}"})
    account_user = Accounts.get_account_user(user, account)
    {api_key, _token} = api_key_fixture(account_user, %{type: :private})
    project = project_fixture(account, %{default_branch: "main"})

    %{
      account: account,
      account_user: account_user,
      api_key: api_key,
      user: user,
      project: project
    }
  end

  defp create!(ctx, attrs \\ %{}) do
    body = Map.merge(%{"title" => "Add login", "source_branch" => "feat/login"}, attrs)
    {:ok, cr} = ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, body)
    cr
  end

  defp facts!(cr, ctx, head, opts \\ []) do
    {:ok, _status, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(head, opts))
    cr
  end

  defp claims!(cr, ctx, head, overrides \\ %{}) do
    {:ok, _status, cr} =
      ChangeRequests.upload_claims(cr, ctx.api_key, claims(front_matter(head, overrides)))

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

  defp verdict(cr), do: ChangeRequests.verdict(cr)
  defp rules(cr), do: Enum.map(verdict(cr).reasons, & &1["rule"])
  defp reload(cr), do: Repo.get!(ChangeRequest, cr.id)

  defp set_state(cr, state, from),
    do: cr |> Ecto.Changeset.change(state: state, closed_from_state: from) |> Repo.update!()

  describe "create/4" do
    test "opens a draft with number 1, the default target branch and the opener", ctx do
      project = project_fixture(ctx.account, %{default_branch: "trunk"})
      body = %{"title" => "Add login", "source_branch" => "feat/login"}
      {:ok, cr} = ChangeRequests.create(ctx.account, project, ctx.api_key, body)

      assert %{number: 1, state: "draft", target_branch: "trunk", head: nil} = cr
      assert cr.opened_by_account_user_id == ctx.account_user.id
      assert cr.opened_by_api_key_id == ctx.api_key.id

      assert %{
               state: "pending",
               head: nil,
               reasons: [%{"rule" => "git_facts_missing", "subject" => []}]
             } =
               verdict(cr)
    end

    test "stores change_id and links as given", ctx do
      links = %{"tickets" => ["GOO-291"]}
      cr = create!(ctx, %{"change_id" => "add-login", "links" => links})

      assert %{change_id: "add-login", links: ^links, link_tickets: ["goo-291"]} =
               reload(cr)
    end

    test "numbers count up after a close and are per project", ctx do
      assert create!(ctx).number == 1
      two = create!(ctx)
      {:ok, _} = ChangeRequests.transition(two, ctx.api_key, :close)
      assert create!(ctx).number == 3

      beta = project_fixture(ctx.account)

      {:ok, cr} =
        ChangeRequests.create(ctx.account, beta, ctx.api_key, %{
          "title" => "t",
          "source_branch" => "b"
        })

      assert cr.number == 1
    end

    test "invalid bodies store nothing", ctx do
      for {body, key} <- [
            {%{"title" => "", "source_branch" => "b"}, "title"},
            {%{"title" => "a\nb", "source_branch" => "b"}, "title"},
            {%{"title" => String.duplicate("a", 257), "source_branch" => "b"}, "title"},
            {%{"title" => "t"}, "source_branch"},
            {%{"title" => "t", "source_branch" => "b", "change_id" => ["a", "b"]}, "change_id"},
            {%{"title" => "t", "source_branch" => "b", "change_id" => "Add_Login"}, "change_id"},
            {%{"title" => "t", "source_branch" => "b", "links" => %{}}, "links"},
            {%{"title" => "t", "source_branch" => "b", "state" => "open"}, "body"}
          ] do
        assert {:error, {:invalid_body, errors}} =
                 ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, body)

        assert Map.has_key?(errors, key), "#{inspect(body)}: #{inspect(errors)}"
      end

      assert Repo.aggregate(ChangeRequest, :count) == 0
    end
  end

  describe "list/2" do
    test "pages by number descending and filters", ctx do
      [one, two, three] = for _ <- 1..3, do: create!(ctx)
      {:ok, _} = ChangeRequests.transition(two, ctx.api_key, :ready)

      {:ok, page} = ChangeRequests.list(ctx.project, %{"limit" => "2"})
      assert Enum.map(page.change_requests, & &1.number) == [3, 2]

      {:ok, last} =
        ChangeRequests.list(ctx.project, %{"limit" => "2", "cursor" => page.next_cursor})

      assert Enum.map(last.change_requests, & &1.number) == [1]
      assert last.next_cursor == nil

      assert {:ok, %{change_requests: [%{number: 2}]}} =
               ChangeRequests.list(ctx.project, %{"state" => "open"})

      assert {:ok, %{change_requests: []}} =
               ChangeRequests.list(ctx.project, %{"source_branch" => "other"})

      assert {:ok, %{change_requests: [_, _]}} =
               ChangeRequests.list(ctx.project, %{
                 "state" => "draft",
                 "source_branch" => "feat/login"
               })

      assert one.number == 1 and three.number == 3

      for {param, value} <- [
            {"state", "approved"},
            {"limit", "0"},
            {"limit", "201"},
            {"cursor", "x"},
            {"source_branch", ""}
          ] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 ChangeRequests.list(ctx.project, %{param => value})

        assert Map.has_key?(errors_on(cs), String.to_atom(param)), param
      end
    end
  end

  describe "transition/3" do
    # {state, closed_from_state, action} => expected
    @table [
      {"draft", nil, :ready, {:ok, "open"}},
      {"draft", nil, :draft, :same},
      {"draft", nil, :close, {:ok, "closed"}},
      {"draft", nil, :reopen, :same},
      {"open", nil, :ready, :same},
      {"open", nil, :draft, {:ok, "draft"}},
      {"open", nil, :close, {:ok, "closed"}},
      {"open", nil, :reopen, :same},
      {"closed", "open", :ready, :conflict},
      {"closed", "open", :draft, :conflict},
      {"closed", "open", :close, :same},
      {"closed", "open", :reopen, {:ok, "open"}},
      {"closed", "draft", :reopen, {:ok, "draft"}},
      {"merged", nil, :ready, :conflict},
      {"merged", nil, :draft, :conflict},
      {"merged", nil, :close, :conflict},
      {"merged", nil, :reopen, :conflict}
    ]

    test "every state and action", ctx do
      for {state, from, action, expected} <- @table do
        cr = ctx |> create!() |> set_state(state, from)
        events_before = Repo.aggregate(Event, :count)
        result = ChangeRequests.transition(cr, ctx.api_key, action)
        label = "#{state} #{action}"

        case expected do
          {:ok, to} ->
            assert {:ok, %{state: ^to}} = result, label

            assert [%Event{from_state: ^state, to_state: ^to}] =
                     Repo.all(from e in Event, where: e.change_request_id == ^cr.id),
                   label

          :same ->
            assert {:ok, %{state: ^state}} = result, label
            assert Repo.aggregate(Event, :count) == events_before, label

          :conflict ->
            assert {:error, :invalid_transition} = result, label
            assert reload(cr).state == state, label
        end
      end
    end

    test "events record the membership and key of any private key", ctx do
      member = user_fixture()
      member_au = account_user_fixture(ctx.account, member, :member)
      {member_key, _} = api_key_fixture(member_au, %{type: :private})
      cr = create!(ctx)

      {:ok, closed} = ChangeRequests.transition(cr, member_key, :close)
      assert closed.closed_from_state == "draft"
      [event] = ChangeRequests.load(closed).history
      assert %{account_user_id: id, api_key_id: key_id} = event
      assert id == member_au.id and key_id == member_key.id
      assert event.account_user.user_id == member.id
    end
  end

  describe "report_merge/3" do
    defp report_merge(ctx, cr, commit \\ sha(0xC1), branch \\ "main"),
      do:
        ChangeRequests.report_merge(cr, ctx.api_key, %{
          "merged_commit" => commit,
          "target_branch" => branch
        })

    test "a mergeable open change request", ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1)) |> claims!(ctx, sha(1))
      {:ok, cr} = ChangeRequests.transition(cr, ctx.api_key, :ready)
      {:ok, merged} = report_merge(ctx, cr)

      assert %{
               state: "merged",
               merged_head: head,
               merged_verdict_state: "mergeable",
               merged_without_mergeable_verdict: false,
               merged_policy_version: 0,
               merged_reasons: []
             } = merged

      assert head == sha(1)

      assert [_ready, %Event{to_state: "merged", from_state: "open"}] =
               ChangeRequests.load(merged).history
    end

    test "needs_review is recorded and flagged, and never changes afterwards", ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1)) |> claims!(ctx, sha(1), %{"door" => "one_way"})
      _ = policy!(ctx, %{}, 0)
      {:ok, merged} = report_merge(ctx, reload(cr))

      assert %{
               merged_verdict_state: "needs_review",
               merged_without_mergeable_verdict: true,
               merged_policy_version: 1
             } = merged

      assert [%{"rule" => "one_way_door"}] = merged.merged_reasons

      _ = policy!(ctx, %{"claims" => %{"one_way_door" => "ignore"}}, 1)

      assert %{merged_policy_version: 1, merged_reasons: [%{"rule" => "one_way_door"}]} =
               reload(cr)
    end

    test "a draft without facts merges as pending without a head", ctx do
      {:ok, merged} = report_merge(ctx, create!(ctx))

      assert %{
               state: "merged",
               merged_head: nil,
               merged_verdict_state: "pending",
               merged_without_mergeable_verdict: true
             } = merged
    end

    test "retries return the stored merge, different reports conflict, closed conflicts", ctx do
      cr = create!(ctx)
      {:ok, first} = report_merge(ctx, cr)
      {:ok, again} = report_merge(ctx, first)
      assert again.merged_at == first.merged_at
      assert {:error, :merge_conflict} = report_merge(ctx, first, sha(0xC2))
      assert {:error, :merge_conflict} = report_merge(ctx, first, sha(0xC1), "release")
      assert reload(cr).merged_commit == sha(0xC1)

      closed = ctx |> create!() |> set_state("closed", "draft")
      assert {:error, :invalid_transition} = report_merge(ctx, closed)
      assert reload(closed).state == "closed"

      assert {:error, {:invalid_body, %{"merged_commit" => _}}} =
               report_merge(ctx, create!(ctx), "ABC123")
    end
  end

  describe "report_git_facts/3" do
    test "first, retry, conflict, moving and re-reporting heads", ctx do
      cr = create!(ctx)
      {:ok, :created, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1)))
      assert cr.head == sha(1)

      {:ok, :retry, ^cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1)))

      different = git_facts(sha(1), merge_base: sha(9))

      assert {:error, :git_facts_conflict} =
               ChangeRequests.report_git_facts(cr, ctx.api_key, different)

      {:ok, :created, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(2)))
      assert cr.head == sha(2)
      {:ok, :retry, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1)))
      assert cr.head == sha(1)
      assert verdict(cr).head == sha(1)
      assert Repo.aggregate(GitFacts, :count) == 2
    end

    test "a report for another target branch is kept beside the first", ctx do
      cr = ctx |> create!(%{"target_branch" => "a"}) |> facts!(ctx, sha(1), target: "a")
      cr = cr |> Ecto.Changeset.change(target_branch: "main") |> Repo.update!()
      ChangeRequests.recompute(cr)

      assert %{reasons: [%{"rule" => "git_facts_missing", "subject" => [head]}], head: head} =
               verdict(cr)

      assert head == sha(1)

      {:ok, :created, cr} =
        ChangeRequests.report_git_facts(
          cr,
          ctx.api_key,
          git_facts(sha(1), files: [file("lib/main.ex")])
        )

      assert {:ok, %{document: %{"diff" => %{"files" => [%{"path" => "lib/main.ex"}]}}}} =
               ChangeRequests.get_git_facts(cr, sha(1))

      assert {:ok, %{target_branch: "a"}} = ChangeRequests.get_git_facts(cr, sha(1), "a")
      assert rules(cr) == ["claims_missing"]
    end

    test "closed and merged change requests accept nothing", ctx do
      for state <- ~w(closed merged) do
        cr = ctx |> create!() |> set_state(state, "draft")

        assert {:error, :not_active} =
                 ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1)))

        assert {:error, :not_active} =
                 ChangeRequests.upload_claims(cr, ctx.api_key, claims(front_matter(sha(1))))
      end

      assert Repo.aggregate(GitFacts, :count) == 0
    end
  end

  describe "upload_claims/3" do
    test "first, identical retry, conflict, and description follows the head", ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1))
      raw = claims(front_matter(sha(1)))
      {:ok, :created, _} = ChangeRequests.upload_claims(cr, ctx.api_key, raw)
      {:ok, :retry, _} = ChangeRequests.upload_claims(cr, ctx.api_key, raw)

      other = claims(front_matter(sha(1), %{"reach" => "Everything"}))
      assert {:error, :claims_conflict} = ChangeRequests.upload_claims(cr, ctx.api_key, other)
      assert ChangeRequests.load(cr).description == raw
      assert verdict(cr).state == "mergeable"

      cr = facts!(cr, ctx, sha(2))
      assert ChangeRequests.load(cr).description == nil
      assert {:ok, %{document: ^raw}} = ChangeRequests.get_claims(cr, sha(1))
      assert rules(cr) == ["claims_missing"]
    end

    test "claims are checked against the current head", ctx do
      cr = create!(ctx)

      assert {:error, {:invalid_body, %{"head" => _}}} =
               ChangeRequests.upload_claims(cr, ctx.api_key, claims(front_matter(sha(1))))

      cr = cr |> facts!(ctx, sha(1)) |> facts!(ctx, sha(2))

      assert {:error, {:invalid_body, %{"head" => _}}} =
               ChangeRequests.upload_claims(cr, ctx.api_key, claims(front_matter(sha(1))))

      assert {:error, {:invalid_body, %{"cr" => _}}} =
               ChangeRequests.upload_claims(
                 cr,
                 ctx.api_key,
                 claims(front_matter(sha(2), %{"cr" => 2}))
               )

      assert {:ok, :created, _} =
               ChangeRequests.upload_claims(
                 cr,
                 ctx.api_key,
                 claims(front_matter(sha(2), %{"cr" => 1}))
               )
    end
  end

  describe "required workflows" do
    import GoodFlows.WorkflowRunFixtures

    defp run!(ctx, commit, outcome, at, attrs \\ %{}) do
      stored_run(
        ctx.account,
        ctx.project,
        Map.merge(%{source_commit: commit, outcome: outcome, started_at: at}, attrs)
      )
    end

    setup ctx do
      _ = policy!(ctx, %{"evidence" => %{"required_workflows" => ["ci"]}}, 0)
      %{cr: ctx |> create!() |> facts!(ctx, sha(1)) |> claims!(ctx, sha(1))}
    end

    test "passed, failed-then-passed and passed-then-failed", ctx do
      assert rules(ctx.cr) == ["required_workflow_missing"]

      run!(ctx, sha(1), "failed", ~U[2026-11-05 10:00:00Z])
      ChangeRequests.recompute(ctx.cr)
      assert rules(ctx.cr) == ["required_workflow_failed"]
      assert verdict(ctx.cr).state == "blocked"

      run!(ctx, sha(1), "passed", ~U[2026-11-05 11:00:00Z])
      ChangeRequests.recompute(ctx.cr)
      assert verdict(ctx.cr).state == "mergeable"

      run!(ctx, sha(1), "failed", ~U[2026-11-05 12:00:00Z])
      ChangeRequests.recompute(ctx.cr)

      assert [%{"rule" => "required_workflow_failed", "subject" => ["ci"]}] =
               verdict(ctx.cr).reasons
    end

    test "dirty runs, cancelled runs, other workflows and earlier heads do not count", ctx do
      run!(ctx, sha(1), "passed", ~U[2026-11-05 10:00:00Z], %{source_dirty: true})
      run!(ctx, sha(9), "passed", ~U[2026-11-05 10:00:00Z])
      run!(ctx, sha(1), "passed", ~U[2026-11-05 10:00:00Z], %{workflow: "e2e"})
      ChangeRequests.recompute(ctx.cr)

      assert [%{"rule" => "required_workflow_missing", "subject" => ["ci"]}] =
               verdict(ctx.cr).reasons

      run!(ctx, sha(1), "passed", ~U[2026-11-05 10:00:00Z], %{source_dirty: false})
      run!(ctx, sha(1), "cancelled", ~U[2026-11-05 11:00:00Z])
      ChangeRequests.recompute(ctx.cr)
      assert rules(ctx.cr) == ["required_workflow_missing"]
    end

    test "a workflow run upload on the head recomputes in the upload", ctx do
      {:ok, _} =
        WorkflowRuns.ingest(ctx.account, ctx.project, ctx.api_key, run_document(sha(1), "passed"))

      assert verdict(ctx.cr).state == "mergeable"
    end

    test "closed change requests are not recomputed; reopen recomputes", ctx do
      {:ok, closed} = ChangeRequests.transition(ctx.cr, ctx.api_key, :close)
      before = verdict(closed)

      {:ok, _} =
        WorkflowRuns.ingest(ctx.account, ctx.project, ctx.api_key, run_document(sha(1), "passed"))

      _ = policy!(ctx, %{}, 1)
      assert verdict(closed) == before

      {:ok, reopened} = ChangeRequests.transition(closed, ctx.api_key, :reopen)
      assert %{state: "mergeable", policy_version: 2} = verdict(reopened)
    end

    test "the head query uses the required-workflow index", ctx do
      # Many runs of `ci` on other commits, analyzed, so the planner sees
      # the query's real selectivity (the sandbox rolls the rows back).
      for n <- 1..300, do: run!(ctx, sha(1_000 + n), "passed", ~U[2026-11-05 10:00:00Z])
      Repo.query!("ANALYZE workflow_runs")

      %{rows: rows} =
        Repo.query!(
          """
          EXPLAIN SELECT DISTINCT ON (workflow) workflow, outcome, run_id FROM workflow_runs
          WHERE account_id = $1 AND project_id = $2 AND source_commit = $3
            AND workflow = ANY($4) AND (source_dirty IS NULL OR source_dirty = false)
          ORDER BY workflow, started_at DESC, run_id DESC
          """,
          [
            Ecto.UUID.dump!(ctx.account.id),
            Ecto.UUID.dump!(ctx.project.id),
            sha(1),
            ["ci"]
          ]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")
      assert plan =~ "workflow_runs_required_workflow_index"
      assert plan =~ ~r/Index Cond: .*source_commit/
    end
  end

  describe "policy writes" do
    test "recompute draft and open change requests inline, not closed ones", ctx do
      open =
        ctx |> create!() |> facts!(ctx, sha(1)) |> claims!(ctx, sha(1), %{"door" => "one_way"})

      {:ok, open} = ChangeRequests.transition(open, ctx.api_key, :ready)

      closed =
        ctx |> create!() |> facts!(ctx, sha(2)) |> claims!(ctx, sha(2), %{"door" => "one_way"})

      {:ok, closed} = ChangeRequests.transition(closed, ctx.api_key, :close)
      assert verdict(open).state == "needs_review"

      _ = policy!(ctx, %{"claims" => %{"one_way_door" => "ignore"}}, 0)
      assert %{state: "mergeable", policy_version: 1} = verdict(open)
      assert %{state: "needs_review", policy_version: 0} = verdict(closed)
    end

    test "inactive-setting changes keep state and reasons", ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1)) |> claims!(ctx, sha(1), %{"door" => "one_way"})
      before = verdict(cr)

      _ =
        policy!(
          ctx,
          %{"merge" => %{"lease_ttl" => "20m"}, "paths" => Document.default()["paths"]},
          0
        )

      after_write = verdict(cr)

      assert {after_write.state, after_write.reasons, after_write.policy_version} ==
               {before.state, before.reasons, 1}
    end
  end
end
