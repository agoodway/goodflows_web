defmodule GoodFlowsWeb.WorkflowRunLive.IndexTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.WorkflowRuns

  @commit String.duplicate("5a4a9715", 5)

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    account_user_fixture(account, user, :member)
    project = project_fixture(account, %{slug: "web", default_branch: "main"})
    %{account: account, project: project}
  end

  defp list_path(ctx, query \\ ""),
    do: "/dashboard/accounts/#{ctx.account.id}/projects/web/runs" <> query

  defp result(name, status) do
    %{
      "name" => name,
      "status" => status,
      "exit_code" => if(status == "passed", do: 0, else: 1),
      "command" => "run #{name}",
      "error" => nil,
      "duration_ms" => 1,
      "started" => true,
      "blocked_ms" => 0,
      "queued_ms" => 0
    }
  end

  defp store!(ctx, attrs) do
    document = Map.merge(minimal(), Map.put_new(attrs, "run_id", Ecto.UUID.generate()))
    {:ok, ack} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)
    ack.run_id
  end

  defp at(minute), do: "2026-11-05T12:#{String.pad_leading(to_string(minute), 2, "0")}:00Z"

  # Broadcasts as the Listener does after a commit (the SQL sandbox never
  # commits), then waits for the debounced refresh.
  defp stored_event(view, ctx, run_id) do
    :erlang.trace(view.pid, true, [:receive])

    Phoenix.PubSub.broadcast(
      GoodFlows.PubSub,
      WorkflowRuns.topic(ctx.project.id),
      {:workflow_run_stored, ctx.project.id, run_id}
    )

    assert_receive {:trace, _pid, :receive, :refresh}, 2_000
    :erlang.trace(view.pid, false, [:receive])
    render(view)
  end

  defp selected(field, value),
    do: ~s(#filter-chip-#{field} [data-selected="#{value}"][aria-selected="true"])

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#runs > li")
    |> LazyHTML.attribute("id")
  end

  describe "list" do
    test "a member sees the project's runs, newest first, with breadcrumbs", ctx do
      old = store!(ctx, %{"started_at" => at(0)})
      new = store!(ctx, %{"started_at" => at(1)})

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert row_ids(view) == ["run-#{new}", "run-#{old}"]

      assert has_element?(
               view,
               ~s(#run-#{new}-link[href="#{list_path(ctx)}/#{new}"]),
               String.slice(new, 0, 8)
             )

      assert has_element?(
               view,
               ~s(nav[aria-label="Breadcrumb"] a[href="/dashboard/accounts/#{ctx.account.id}/projects/web"]),
               "web"
             )

      assert has_element?(view, ~s(nav[aria-label="Breadcrumb"] [aria-current="page"]), "Runs")
    end

    test "a project of another account redirects with Project not found", ctx do
      other = account_fixture()
      project_fixture(other, %{slug: "secret"})
      projects = "/dashboard/accounts/#{ctx.account.id}/projects"

      assert {:error,
              {:live_redirect, %{to: ^projects, flash: %{"error" => "Project not found"}}}} =
               live(ctx.conn, "/dashboard/accounts/#{ctx.account.id}/projects/secret/runs")
    end

    test "51 runs: Load more shows all and disappears", ctx do
      for n <- 1..51,
          do:
            stored_run(ctx.account, ctx.project, %{
              started_at: ~U[2026-11-05 12:00:00Z] |> DateTime.add(n, :second)
            })

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      assert length(row_ids(view)) == 50

      view |> element("#load-more") |> render_click()
      assert length(row_ids(view)) == 51
      refute has_element?(view, "#load-more")
    end

    test "no runs shows how to upload them and links to API keys", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert has_element?(view, "#runs-empty", "history = true")

      assert has_element?(
               view,
               ~s(#empty-api-keys[href="/dashboard/accounts/#{ctx.account.id}/api-keys"])
             )
    end

    test "filters that match nothing name them and offer to clear", ctx do
      store!(ctx, %{"source" => %{"commit" => @commit, "branch" => "main"}})

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?branch=nope"))

      assert has_element?(view, "#runs-no-match", "branch")
      assert has_element?(view, "#runs-no-match", "nope")

      view |> element("#empty-clear-filters") |> render_click()
      assert_patch(view, list_path(ctx))
      assert length(row_ids(view)) == 1
    end
  end

  describe "filters" do
    setup ctx do
      %{
        ci_failed:
          store!(ctx, %{
            "workflow" => "ci",
            "outcome" => "failed",
            "results" => [result("test", "failed")],
            "started_at" => at(1),
            "source" => %{"commit" => @commit, "branch" => "main"}
          }),
        ci_passed:
          store!(ctx, %{
            "workflow" => "ci",
            "started_at" => at(2),
            "source" => %{"commit" => @commit, "branch" => "feature/x"}
          }),
        lint:
          store!(ctx, %{
            "workflow" => "lint",
            "started_at" => at(3),
            "source" => %{"commit" => @commit, "branch" => "main"}
          })
      }
    end

    test "filters in the URL are applied and shown as active", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?workflow=ci&outcome=failed"))

      assert row_ids(view) == ["run-#{ctx.ci_failed}"]
      assert has_element?(view, selected("workflow", "ci"))
      assert has_element?(view, selected("outcome", "failed"))
    end

    test "picking a value in the filter bar patches the URL with the API name", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?workflow=lint"))

      view
      |> element("#select-opt-workflow-0")
      |> render_hook("select_option_value", %{"id" => "workflow", "selected" => "ci"})

      assert_patch(view, list_path(ctx, "?workflow=ci"))
      assert row_ids(view) == ["run-#{ctx.ci_passed}", "run-#{ctx.ci_failed}"]
    end

    test "a short commit is not applied and the error names the commit field", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      view
      |> element("#always-on-commit")
      |> render_change(%{"filter" => %{"commit" => "5a4a971"}})

      assert_patch(view, list_path(ctx, "?commit=5a4a971"))

      assert has_element?(
               view,
               "#filter-error-commit",
               "Commit must be a full 40- or 64-character SHA"
             )

      assert has_element?(view, ~s(#filter-text-commit[value="5a4a971"]))
      assert length(row_ids(view)) == 3
    end

    test "an invalid filter is dropped while the valid ones stay applied", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?workflow=ci&commit=5a4a971"))

      assert row_ids(view) == ["run-#{ctx.ci_passed}", "run-#{ctx.ci_failed}"]
      assert has_element?(view, selected("workflow", "ci"))
      assert has_element?(view, "#filter-error-commit")
      refute has_element?(view, "#filter-error-workflow")
    end

    test "removing one filter keeps the others", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?workflow=ci&branch=main"))
      assert row_ids(view) == ["run-#{ctx.ci_failed}"]

      view
      |> element(~s(#filter-chip-branch button[aria-label="Remove filter"]))
      |> render_click()

      assert_patch(view, list_path(ctx, "?workflow=ci"))
      assert row_ids(view) == ["run-#{ctx.ci_passed}", "run-#{ctx.ci_failed}"]
    end

    test "the API query is copyable with the active filters", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?branch=main&outcome=failed"))

      query = "/api/v1/projects/web/workflow-runs?branch=main&outcome=failed"
      assert has_element?(view, "#api-query-url", query)

      assert has_element?(
               view,
               ~s(#copy-api-query[data-copy-value="#{query}"][aria-label="Copy API query"])
             )
    end

    test "clicking a row's branch applies the branch filter", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      view |> element("#run-#{ctx.lint}-branch") |> render_click()
      assert_patch(view, list_path(ctx, "?branch=main"))
      assert row_ids(view) == ["run-#{ctx.lint}", "run-#{ctx.ci_failed}"]
    end
  end

  describe "rows" do
    test "a pull request run shows its trigger and CI link", ctx do
      ci = %{
        "provider" => "github_actions",
        "event" => "pull_request",
        "pull_request" => 42,
        "url" => "https://github.com/a/b/actions/runs/1"
      }

      id = store!(ctx, %{"ci" => ci})
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert has_element?(view, "#run-#{id}-trigger", "pull_request #42")
      assert has_element?(view, ~s(#run-#{id}-ci[href="#{ci["url"]}"]))
    end

    test "a local run shows local and no branch or commit", ctx do
      id = store!(ctx, %{})
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert has_element?(view, "#run-#{id}-trigger", "local")
      refute has_element?(view, "#run-#{id}-branch")
      refute has_element?(view, "#run-#{id}-commit")
    end

    test "a dirty run marks its commit", ctx do
      id = store!(ctx, %{"source" => %{"commit" => @commit, "dirty" => true}})
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert has_element?(view, "#run-#{id}-commit", String.slice(@commit, 0, 7))
      assert has_element?(view, "#run-#{id}-dirty")
    end

    test "a run with many failed jobs names 3 and the rest as +N more", ctx do
      results = for name <- ~w(test lint format credo dialyzer), do: result(name, "failed")
      id = store!(ctx, %{"outcome" => "failed", "results" => results})

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      tags =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#run-#{id}-failed-jobs code")
        |> Enum.map(&LazyHTML.text/1)

      assert tags == ~w(test lint format)
      assert has_element?(view, "#run-#{id}-failed-jobs", "+2 more")
    end

    test "a called run folds under its stored parent and expands", ctx do
      parent = store!(ctx, %{"started_at" => at(0)})

      child =
        store!(ctx, %{
          "workflow" => "suite",
          "started_at" => at(1),
          "parent_run_id" => parent,
          "caller_job" => "call-suite"
        })

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert row_ids(view) == ["run-#{parent}"]
      assert has_element?(view, "#run-#{parent}-expand[aria-expanded=false]", "Calls 1 run")
      refute has_element?(view, "#run-#{parent}-child-#{child}")

      view |> element("#run-#{parent}-expand") |> render_click()
      assert has_element?(view, "#run-#{parent}-expand[aria-expanded=true]")
      assert has_element?(view, "#run-#{parent}-child-#{child}", "suite")
    end

    test "a run whose parent was not uploaded is listed and marked", ctx do
      id = store!(ctx, %{"parent_run_id" => Ecto.UUID.generate(), "caller_job" => "call"})
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert row_ids(view) == ["run-#{id}"]
      assert has_element?(view, "#run-#{id}-missing-parent", "not uploaded")
    end

    test "filtering by the called workflow lists the called run as its own row", ctx do
      parent = store!(ctx, %{"started_at" => at(0)})

      child =
        store!(ctx, %{
          "workflow" => "suite",
          "started_at" => at(1),
          "parent_run_id" => parent,
          "caller_job" => "call-suite"
        })

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?workflow=suite"))
      assert row_ids(view) == ["run-#{child}"]
      refute has_element?(view, "#run-#{child}-missing-parent")
    end
  end

  describe "live updates" do
    test "a new run matching the filter appears at the top, another does not", ctx do
      old = store!(ctx, %{"workflow" => "ci", "started_at" => at(0)})
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?workflow=ci"))

      ci = store!(ctx, %{"workflow" => "ci", "started_at" => at(5)})
      lint = store!(ctx, %{"workflow" => "lint", "started_at" => at(6)})
      stored_event(view, ctx, lint)

      assert row_ids(view) == ["run-#{ci}", "run-#{old}"]
      assert has_element?(view, selected("workflow", "ci"))
    end

    test "51 loaded rows stay loaded after a refresh", ctx do
      for n <- 1..51,
          do:
            stored_run(ctx.account, ctx.project, %{
              started_at: DateTime.add(~U[2026-11-05 12:00:00Z], n, :second)
            })

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      view |> element("#load-more") |> render_click()
      assert length(row_ids(view)) == 51

      new = store!(ctx, %{"started_at" => "2026-11-06T12:00:00Z"})
      stored_event(view, ctx, new)

      assert length(row_ids(view)) == 52
      assert hd(row_ids(view)) == "run-#{new}"
    end

    test "more than 200 loaded rows stay loaded after a refresh", ctx do
      for n <- 1..210,
          do:
            stored_run(ctx.account, ctx.project, %{
              started_at: DateTime.add(~U[2026-11-05 12:00:00Z], n, :second)
            })

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      for _page <- 1..4, do: view |> element("#load-more") |> render_click()
      loaded = row_ids(view)
      assert length(loaded) == 210
      refute has_element?(view, "#load-more")

      new = store!(ctx, %{"started_at" => "2026-11-06T12:00:00Z"})
      stored_event(view, ctx, new)

      assert row_ids(view) == ["run-#{new}" | loaded]
    end

    test "two runs stored before one refresh push no loaded row out", ctx do
      for n <- 1..60,
          do:
            stored_run(ctx.account, ctx.project, %{
              started_at: DateTime.add(~U[2026-11-05 12:00:00Z], n, :second)
            })

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      loaded = row_ids(view)
      assert length(loaded) == 50

      first = store!(ctx, %{"started_at" => "2026-11-06T12:00:00Z"})
      second = store!(ctx, %{"started_at" => "2026-11-06T12:01:00Z"})
      stored_event(view, ctx, second)

      assert row_ids(view) == ["run-#{second}", "run-#{first}" | loaded]

      view |> element("#load-more") |> render_click()
      all = row_ids(view)
      assert length(all) == 62
      assert all == Enum.uniq(all)

      {:ok, %{runs: runs}} = WorkflowRuns.list_runs(ctx.account, ctx.project, %{"limit" => 100})
      assert all == for(run <- runs, do: "run-#{run.run_id}")

      refute has_element?(view, "#load-more")
    end

    test "an exact retry adds no row", ctx do
      document = Map.put(minimal(), "run_id", Ecto.UUID.generate())
      {:ok, _ack} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      {:ok, %{duplicate: true}} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)
      stored_event(view, ctx, document["run_id"])

      assert row_ids(view) == ["run-#{document["run_id"]}"]
    end
  end
end
