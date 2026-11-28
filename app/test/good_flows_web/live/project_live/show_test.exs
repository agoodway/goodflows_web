defmodule GoodFlowsWeb.ProjectLive.ShowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, Verdict}
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.StoredChanges
  alias GoodFlows.WorkflowRuns

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    account_user = account_user_fixture(account, user, :member)
    project = project_fixture(account, %{slug: "web", default_branch: "main"})
    {api_key, _token} = api_key_fixture(account_user, %{type: :private})
    %{account: account, project: project, api_key: api_key}
  end

  defp path(ctx), do: "/dashboard/accounts/#{ctx.account.id}/projects/web"

  defp run!(ctx, workflow, outcome, started_at, attrs \\ %{}) do
    run_id = Ecto.UUID.generate()

    stored_run(
      ctx.account,
      ctx.project,
      Map.merge(
        %{run_id: run_id, workflow: workflow, outcome: outcome, started_at: started_at},
        attrs
      )
    )

    run_id
  end

  defp cr!(ctx, state, verdict_state) do
    {:ok, cr} =
      ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
        "title" => "Change #{System.unique_integer([:positive])}",
        "source_branch" => "feat/#{System.unique_integer([:positive])}"
      })

    Repo.update_all(from(c in ChangeRequest, where: c.id == ^cr.id), set: [state: state])
    Repo.delete_all(from v in Verdict, where: v.change_request_id == ^cr.id)

    if verdict_state do
      %Verdict{}
      |> Verdict.changeset(%{
        change_request_id: cr.id,
        state: verdict_state,
        policy_version: 1,
        reasons: [],
        inputs: %{},
        computed_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    cr
  end

  test "a member sees the slug, default branch, both cards and breadcrumbs", ctx do
    {:ok, view, _html} = live(ctx.conn, path(ctx))

    assert has_element?(view, "#project-slug", "web")
    assert has_element?(view, "#project-default-branch", "main")
    document = view |> render() |> LazyHTML.from_fragment()

    cards =
      document
      |> LazyHTML.query("#runs-card, #change-requests-card")
      |> LazyHTML.attribute("id")

    assert cards == ["change-requests-card", "runs-card"]

    crumbs =
      document
      |> LazyHTML.query(~s(nav[aria-label="Breadcrumb"] li))
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace("/", "") |> String.trim()))

    assert crumbs == ["Dashboard", "Projects", "web"]
    assert has_element?(view, ~s(#sidebar a[aria-current="page"]), "Projects")
  end

  test "a project of another account redirects with Project not found", ctx do
    other = account_fixture()
    project_fixture(other, %{slug: "secret"})
    projects = "/dashboard/accounts/#{ctx.account.id}/projects"

    assert {:error, {:live_redirect, %{to: ^projects, flash: %{"error" => "Project not found"}}}} =
             live(ctx.conn, "/dashboard/accounts/#{ctx.account.id}/projects/secret")
  end

  test "the latest run of each workflow on the default branch, dirty or not", ctx do
    run!(ctx, "ci", "failed", ~U[2026-11-05 10:00:00Z], %{source_branch: "main"})
    passed = run!(ctx, "ci", "passed", ~U[2026-11-05 11:00:00Z], %{source_branch: "main"})
    run!(ctx, "lint", "passed", ~U[2026-11-05 12:00:00Z], %{source_branch: "feature/x"})

    dirty =
      run!(ctx, "e2e", "failed", ~U[2026-11-05 13:00:00Z], %{
        source_branch: "main",
        source_commit: String.duplicate("ab", 20),
        source_dirty: true
      })

    {:ok, view, _html} = live(ctx.conn, path(ctx))

    assert has_element?(view, "#latest-ci", "Passed")
    assert has_element?(view, ~s(#latest-ci-link[href="#{path(ctx)}/runs/#{passed}"]))
    refute has_element?(view, "#latest-lint")
    assert has_element?(view, ~s(#latest-e2e-link[href="#{path(ctx)}/runs/#{dirty}"]))
  end

  test "recent runs show the 5 newest and link to the run list", ctx do
    ids =
      for n <- 1..8,
          do: run!(ctx, "ci", "passed", DateTime.add(~U[2026-11-05 10:00:00Z], n, :minute))

    {:ok, view, _html} = live(ctx.conn, path(ctx))

    shown =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#recent-runs ul > li")
      |> LazyHTML.attribute("id")

    assert shown == for(id <- ids |> Enum.reverse() |> Enum.take(5), do: "recent-#{id}")
    assert has_element?(view, ~s(#runs-link[href="#{path(ctx)}/runs"]))
  end

  test "a recent run that called runs says how many, as the run list does", ctx do
    parent = run!(ctx, "ci", "passed", ~U[2026-11-05 10:00:00Z])

    for n <- 1..2,
        do:
          run!(ctx, "suite", "passed", DateTime.add(~U[2026-11-05 10:00:00Z], n, :minute), %{
            parent_run_id: parent
          })

    {:ok, view, _html} = live(ctx.conn, path(ctx))

    shown =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#recent-runs ul > li")
      |> LazyHTML.attribute("id")

    assert shown == ["recent-#{parent}"]
    assert has_element?(view, "#recent-#{parent}-calls", "Calls 2 runs")
    refute has_element?(view, "#recent-#{parent}-expand")
  end

  test "a project with no runs shows how to upload them and links to API keys", ctx do
    {:ok, view, _html} = live(ctx.conn, path(ctx))

    assert has_element?(view, "#runs-empty", "history = true")

    assert has_element?(
             view,
             ~s(#runs-empty-api-keys[href="/dashboard/accounts/#{ctx.account.id}/api-keys"])
           )
  end

  test "verdict counts of active change requests, a missing verdict as pending", ctx do
    cr!(ctx, "open", "blocked")
    cr!(ctx, "open", "blocked")
    mergeable = cr!(ctx, "open", "mergeable")
    cr!(ctx, "draft", nil)
    cr!(ctx, "merged", "mergeable")

    {:ok, view, _html} = live(ctx.conn, path(ctx))

    assert has_element?(view, "#count-mergeable dd", "1")
    assert has_element?(view, "#count-needs_review dd", "0")
    assert has_element?(view, "#count-blocked dd", "2")
    assert has_element?(view, "#count-pending dd", "1")

    cr_path = "#{path(ctx)}/change-requests/#{mergeable.number}"
    assert has_element?(view, ~s(#change-request-#{mergeable.number} a[href="#{cr_path}"]))
  end

  test "only merged and closed change requests: zero counts and the list link", ctx do
    cr!(ctx, "merged", "mergeable")
    cr!(ctx, "closed", nil)

    {:ok, view, _html} = live(ctx.conn, path(ctx))

    for state <- ~w(mergeable needs_review blocked pending),
        do: assert(has_element?(view, "#count-#{state} dd", "0"))

    assert has_element?(view, "#no-active-change-requests", "No change request is active")
    assert has_element?(view, ~s(#change-requests-link[href="#{path(ctx)}/change-requests"]))
  end

  test "a new run on the default branch shows without a reload", ctx do
    run!(ctx, "ci", "failed", ~U[2026-11-05 10:00:00Z], %{source_branch: "main"})
    {:ok, view, _html} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#latest-ci", "Failed")

    document =
      Map.merge(minimal(), %{
        "run_id" => Ecto.UUID.generate(),
        "started_at" => "2026-11-05T11:00:00Z",
        "source" => %{"commit" => String.duplicate("ab", 20), "branch" => "main"}
      })

    {:ok, %{run_id: run_id}} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)

    :erlang.trace(view.pid, true, [:receive])

    Phoenix.PubSub.broadcast(
      GoodFlows.PubSub,
      WorkflowRuns.topic(ctx.project.id),
      {:workflow_run_stored, ctx.project.id, run_id}
    )

    assert_receive {:trace, _pid, :receive, :refresh}, 2_000
    assert has_element?(view, "#latest-ci", "Passed")
    assert has_element?(view, "#recent-#{run_id}")
  end

  describe "Changes card (scenarios 8, 17)" do
    defp push_change!(ctx, id, status) do
      change_md =
        "---\nformat: goodflows-change/1\nid: #{id}\nstatus: #{status}\n---\n\n## Why\n"

      {:ok, :created, version, _replaced} =
        StoredChanges.push(ctx.project, ctx.api_key, %{
          "files" => %{"change.md" => change_md},
          "source" => %{"commit" => nil, "branch" => "main", "dirty" => false}
        })

      version
    end

    defp active_changes(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#active-changes > li")
      |> LazyHTML.attribute("data-change-id")
    end

    test "counts proposed and approved changes and lists the 5 latest active ones", ctx do
      pushed =
        for {status, n} <- [
              {"proposed", 1},
              {"archived", 1},
              {"approved", 1},
              {"proposed", 2},
              {"approved", 2},
              {"archived", 2},
              {"approved", 3},
              {"proposed", 3},
              {"approved", 4}
            ] do
          push_change!(ctx, "#{status}-#{n}", status)
          {"#{status}-#{n}", status}
        end

      {:ok, view, _html} = live(ctx.conn, path(ctx))

      assert has_element?(view, "#changes-count-proposed", "3")
      assert has_element?(view, "#changes-count-approved", "4")

      expected =
        pushed
        |> Enum.reverse()
        |> Enum.reject(&(elem(&1, 1) == "archived"))
        |> Enum.take(5)
        |> Enum.map(&elem(&1, 0))

      assert active_changes(view) == expected

      assert has_element?(
               view,
               ~s(#active-changes a[href="#{path(ctx)}/changes/approved-4"]),
               "approved-4"
             )

      assert has_element?(view, ~s(#changes-link[href="#{path(ctx)}/changes"]))
      refute has_element?(view, "#changes-card-empty")
    end

    test "a project with no stored changes shows the push empty state", ctx do
      {:ok, view, _html} = live(ctx.conn, path(ctx))

      assert has_element?(view, "#changes-card-empty", "goodflows change push")
      assert has_element?(view, "#changes-card-empty", "newer than 0.10.0")
      refute has_element?(view, "#no-active-changes")
    end

    test "a project whose changes are all archived says no change is active", ctx do
      push_change!(ctx, "done", "archived")
      {:ok, view, _html} = live(ctx.conn, path(ctx))

      assert has_element?(view, "#changes-count-proposed", "0")
      assert has_element?(view, "#changes-count-approved", "0")
      assert has_element?(view, "#no-active-changes", "No change is active")
      refute has_element?(view, "#changes-card-empty")
      assert has_element?(view, ~s(#changes-link[href="#{path(ctx)}/changes"]))
    end

    test "a push refreshes the counts", ctx do
      push_change!(ctx, "first", "proposed")
      {:ok, view, _html} = live(ctx.conn, path(ctx))
      assert has_element?(view, "#changes-count-proposed", "1")

      push_change!(ctx, "second", "proposed")
      :erlang.trace(view.pid, true, [:receive])

      Phoenix.PubSub.broadcast(
        GoodFlows.PubSub,
        ProjectEvents.topic(ctx.project.id),
        {:project_event, ctx.project.id}
      )

      assert_receive {:trace, _pid, :receive, :refresh}, 2_000
      assert has_element?(view, "#changes-count-proposed", "2")
      assert active_changes(view) == ["second", "first"]
    end
  end
end
