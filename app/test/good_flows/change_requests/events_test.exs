defmodule GoodFlows.ChangeRequests.EventsTest do
  @moduledoc """
  The project events that change request edits record, the dashboard's
  `list/3` options, and the actor a dashboard decision is stored with.
  """
  use GoodFlows.DataCase, async: true

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.MergeLeases
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Review
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.Decision
  alias GoodFlows.VerifyRuns
  alias GoodFlows.WorkflowRuns

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "EV #{System.unique_integer()}"})
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

  defp facts!(cr, ctx, head) do
    {:ok, _status, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(head))
    cr
  end

  defp claims!(cr, ctx, head, overrides \\ %{}) do
    {:ok, _status, cr} =
      ChangeRequests.upload_claims(cr, ctx.api_key, claims(front_matter(head, overrides)))

    cr
  end

  defp events(ctx, type),
    do:
      Repo.all(
        from e in Event,
          where: e.project_id == ^ctx.project.id and e.type == ^type,
          order_by: e.id
      )

  defp reload(cr), do: Repo.get!(ChangeRequest, cr.id)

  defp set_state(cr, state),
    do: cr |> Ecto.Changeset.change(state: state) |> Repo.update!()

  describe "list/3 options" do
    test "states: ~w(draft open) with the verdict preloaded; the API still refuses active",
         ctx do
      [closed, merged, open, draft] = for _ <- 1..4, do: create!(ctx)
      set_state(closed, "closed")
      set_state(merged, "merged")
      {:ok, _open} = ChangeRequests.transition(open, ctx.api_key, :ready)

      {:ok, %{change_requests: rows}} =
        ChangeRequests.list(ctx.project, %{}, states: ~w(draft open), preload: [:verdict])

      assert Enum.map(rows, & &1.number) == [draft.number, open.number]
      assert Enum.all?(rows, &match?(%{verdict: %{state: "pending"}}, &1))

      assert {:error, changeset} = ChangeRequests.list(ctx.project, %{"state" => "active"})
      assert %{state: [_]} = errors_on(changeset)
    end
  end

  describe "cr_retargeted" do
    test "a retarget records one event with the key; the same target and lease_held none",
         ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1)) |> claims!(ctx, sha(1))
      {:ok, cr} = ChangeRequests.transition(cr, ctx.api_key, :ready)

      {:ok, cr} = ChangeRequests.retarget(cr, ctx.api_key, %{"target_branch" => "release/2"})
      {:ok, cr} = ChangeRequests.retarget(cr, ctx.api_key, %{"target_branch" => "release/2"})

      assert [event] = events(ctx, "cr_retargeted")
      assert event.data == %{"from" => "main", "to" => "release/2"}
      assert event.change_request_number == cr.number
      assert event.actor_key_id == ctx.api_key.id
      assert event.actor_membership_id == ctx.account_user.id

      other = ctx |> create!() |> facts!(ctx, sha(2)) |> claims!(ctx, sha(2))
      {:ok, other} = ChangeRequests.transition(other, ctx.api_key, :ready)

      {:ok, :created, _lease} =
        MergeLeases.acquire(reload(other), ctx.api_key, %{"head" => sha(2), "base" => sha(0)})

      assert {:error, {:coded_conflict, "lease_held", _}} =
               ChangeRequests.retarget(reload(other), ctx.api_key, %{"target_branch" => "dev"})

      assert length(events(ctx, "cr_retargeted")) == 1
    end
  end

  describe "cr_parent_changed" do
    test "set, change and clear record three events; setting the same parent none", ctx do
      [first, second, child] = for _ <- 1..3, do: create!(ctx)

      {:ok, child} = ChangeRequests.set_parent(child, ctx.api_key, %{"number" => second.number})
      {:ok, child} = ChangeRequests.set_parent(child, ctx.api_key, %{"number" => second.number})
      {:ok, child} = ChangeRequests.set_parent(child, ctx.api_key, %{"number" => first.number})
      {:ok, _child} = ChangeRequests.clear_parent(child, ctx.api_key)

      changes = events(ctx, "cr_parent_changed")

      assert Enum.map(changes, & &1.data) == [
               %{"from" => nil, "to" => second.number},
               %{"from" => second.number, "to" => first.number},
               %{"from" => first.number, "to" => nil}
             ]

      assert Enum.all?(changes, &(&1.change_request_number == child.number))
      assert Enum.all?(changes, &(&1.actor_key_id == ctx.api_key.id))
    end
  end

  describe "dashboard actor" do
    test "a scenario set decision stores channel dashboard and no key", ctx do
      cr = create!(ctx, %{"openspec_change" => "add-export"})

      {:ok, :created, version} =
        ScenarioSets.upload(cr, ctx.api_key, set_body(intent_fm("add-export")))

      actor = Review.dashboard_actor(ctx.account_user)

      {:ok, {:created, _decision}} =
        Repo.transaction(fn ->
          cr = ChangeRequests.lock_active(cr)

          ScenarioSets.record_decision(cr, actor, %{
            decision: "approve",
            digest: version.digest,
            note: nil
          })
        end)

      assert [%Decision{channel: "dashboard", api_key_id: nil} = decision] = Repo.all(Decision)
      assert decision.account_user_id == ctx.account_user.id
      assert ScenarioSets.approved?(version, ScenarioSets.approved_digests(cr))
    end
  end

  describe "workflow_run_stored" do
    test "a run on an active head records one event per change request with the key", ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1))
      doc = run_document(sha(1), "passed")

      {:ok, %{duplicate: false}} = WorkflowRuns.ingest(ctx.account, ctx.project, ctx.api_key, doc)

      assert [event] = events(ctx, "workflow_run_stored")
      assert event.change_request_number == cr.number

      assert event.data == %{
               "run_id" => doc["run_id"],
               "workflow" => "ci",
               "outcome" => "passed",
               "commit" => sha(1)
             }

      assert event.actor_key_id == ctx.api_key.id
      assert event.actor_membership_id == ctx.account_user.id

      {:ok, %{duplicate: true}} = WorkflowRuns.ingest(ctx.account, ctx.project, ctx.api_key, doc)
      assert length(events(ctx, "workflow_run_stored")) == 1
    end

    test "a run on no active head, or on a closed one, records none", ctx do
      cr = ctx |> create!() |> facts!(ctx, sha(1))
      {:ok, _closed} = ChangeRequests.transition(cr, ctx.api_key, :close)

      for commit <- [sha(1), sha(2)] do
        {:ok, _} =
          WorkflowRuns.ingest(
            ctx.account,
            ctx.project,
            ctx.api_key,
            run_document(commit, "passed")
          )
      end

      assert events(ctx, "workflow_run_stored") == []
    end
  end

  describe "verify_run_stored" do
    setup ctx do
      cr = create!(ctx, %{"source_branch" => "feat/x"})
      {:ok, :created, version} = ScenarioSets.upload(cr, ctx.api_key, set_body(diff_fm(sha(1))))
      %{cr: cr, digest: version.digest}
    end

    test "a final run records one event with its set", ctx do
      doc = run_doc(ctx.digest, "diff", sha(1), [result("D1")])
      {:ok, %{run: run}} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.api_key, doc)

      assert [event] = events(ctx, "verify_run_stored")
      assert event.change_request_number == ctx.cr.number

      assert event.data == %{
               "run_id" => run.run_id,
               "commit" => sha(1),
               "source" => "diff",
               "digest" => ctx.digest
             }

      assert event.actor_key_id == ctx.api_key.id

      {:ok, %{duplicate: true}} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.api_key, doc)
      assert length(events(ctx, "verify_run_stored")) == 1
    end

    test "an uploading run records none until its commit makes it final", ctx do
      bytes = "shot"

      doc =
        run_doc(ctx.digest, "diff", sha(1), [result("D1")], artifacts: [artifact("a", bytes)])

      {:ok, %{run: run, uploads: [upload]}} =
        VerifyRuns.ingest(ctx.account, ctx.project, ctx.api_key, doc)

      assert events(ctx, "verify_run_stored") == []

      :ok = Fake.put(upload.upload_url, upload.upload_headers, bytes)
      {:ok, _final} = VerifyRuns.commit(ctx.project, ctx.api_key, run.run_id)
      {:ok, _final} = VerifyRuns.commit(ctx.project, ctx.api_key, run.run_id)

      assert [%{data: %{"run_id" => run_id}}] = events(ctx, "verify_run_stored")
      assert run_id == run.run_id
    end
  end
end
