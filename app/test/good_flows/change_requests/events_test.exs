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
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.MergeLeases
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Review
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.Decision

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
end
