defmodule GoodFlowsWeb.WorkflowRunLive.ShowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures, only: [git_facts: 1]
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures
  import GoodFlows.WorkflowRunFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.ChangeRequests
  alias GoodFlows.Repo
  alias GoodFlows.TestReports.{Document, Report}
  alias GoodFlows.WorkflowRuns

  @report_run "67f7946d-136b-4608-ab01-e1f251a09754"

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    account_user = account_user_fixture(account, user, :member)
    project = project_fixture(account, %{slug: "web", default_branch: "main"})
    %{account: account, account_user: account_user, project: project}
  end

  defp run_path(ctx, run_id, slug \\ "web"),
    do: "/dashboard/accounts/#{ctx.account.id}/projects/#{slug}/runs/#{run_id}"

  defp store!(ctx, document, project \\ nil) do
    {:ok, ack} = WorkflowRuns.ingest(ctx.account, project || ctx.project, nil, document)
    ack.run_id
  end

  defp result(name, status, extra \\ %{}) do
    Map.merge(
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
      },
      extra
    )
  end

  defp job_names(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#jobs > li")
    |> LazyHTML.attribute("data-name")
  end

  describe "summary" do
    test "breadcrumbs end in the short run id and link the slug to the overview", ctx do
      id = store!(ctx, goodflows("child"))
      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))

      crumbs = ~s(nav[aria-label="Breadcrumb"])
      overview = "/dashboard/accounts/#{ctx.account.id}/projects/web"
      assert has_element?(view, ~s(#{crumbs} a[href="#{overview}"]), "web")
      assert has_element?(view, ~s(#{crumbs} a[href="#{overview}/runs"]), "Runs")
      assert has_element?(view, ~s(#{crumbs} [aria-current="page"]), "0e54fb55")
    end

    test "a run of another project redirects to this project's run list", ctx do
      other = project_fixture(ctx.account, %{slug: "b"})
      id = store!(ctx, minimal())
      list = "/dashboard/accounts/#{ctx.account.id}/projects/b/runs"

      assert {:error, {:live_redirect, %{to: ^list, flash: %{"error" => "Run not found"}}}} =
               live(ctx.conn, run_path(ctx, id, other.slug))
    end

    test "an uppercase run id redirects with Run not found", ctx do
      id = store!(ctx, goodflows("child"))
      list = "/dashboard/accounts/#{ctx.account.id}/projects/web/runs"
      assert String.upcase(id) != id

      assert {:error, {:live_redirect, %{to: ^list, flash: %{"error" => "Run not found"}}}} =
               live(ctx.conn, run_path(ctx, String.upcase(id)))
    end

    test "a minimal run shows outcome, workflow, timing and host only", ctx do
      id = store!(ctx, minimal())
      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))

      assert has_element?(view, "#run-outcome", "Passed")
      assert has_element?(view, "#run-workflow", "ci")
      assert has_element?(view, "#run-id", id)
      assert has_element?(view, "#summary-started", "2026-11-05 12:00 UTC")
      assert has_element?(view, "#summary-duration", "0ms")
      assert has_element?(view, "#summary-host", "linux")

      for absent <-
            ~w(#summary-commit #summary-branch #summary-ci #summary-threads #summary-tickets #summary-parent) do
        refute has_element?(view, absent)
      end
    end

    test "full.json shows its CI link, host and thread links", ctx do
      thread = "https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"

      document =
        Map.put(goodflows("full"), "links", %{"threads" => [thread], "tickets" => ["GOO-1"]})

      id = store!(ctx, document)

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))

      assert has_element?(view, ~s(#summary-ci-link[href="#{document["ci"]["url"]}"]))
      assert has_element?(view, "#summary-ci", "pull_request #42")
      assert has_element?(view, "#summary-host", "linux · x86_64 · 8 CPUs")
      assert has_element?(view, ~s(#summary-threads a[href="#{thread}"]))
      assert has_element?(view, "#summary-tickets", "GOO-1")
      assert has_element?(view, "#summary-commit", document["source"]["commit"])
      assert has_element?(view, "#summary-branch", "feature/login")
      assert has_element?(view, "#summary-requested", "integration")
    end
  end

  describe "jobs" do
    test "failures come first; the result-order control restores result order", ctx do
      results = [result("compile", "passed"), result("test", "failed"), result("lint", "passed")]
      id = store!(ctx, Map.merge(minimal(), %{"outcome" => "failed", "results" => results}))

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))
      assert hd(job_names(view)) == "test"
      assert has_element?(view, "#order-failures-first.ui-button-soft[aria-pressed=true]")

      view |> element("#order-results") |> render_click()
      assert job_names(view) == ~w(compile test lint)
      assert has_element?(view, "#order-results.ui-button-soft[aria-pressed=true]")
      assert has_element?(view, "#order-failures-first.ui-button-ghost[aria-pressed=false]")
    end

    test "a job's exit code and error are shown", ctx do
      results = [
        result("test", "failed", %{"exit_code" => 2, "error" => "mix test exited with 2"})
      ]

      id = store!(ctx, Map.merge(minimal(), %{"outcome" => "failed", "results" => results}))
      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))

      assert has_element?(view, "#job-0-exit", "exit 2")
      assert has_element?(view, "#job-0-error", "mix test exited with 2")
      assert has_element?(view, "#job-0-command", "run test")
    end

    test "a graph job without a result is listed as not run", ctx do
      document = goodflows("full")
      graph_job = hd(document["graph"]["jobs"])

      deploy = Map.merge(graph_job, %{"name" => "deploy", "depends_on" => []})
      document = put_in(document, ["graph", "jobs"], document["graph"]["jobs"] ++ [deploy])

      case WorkflowRuns.ingest(ctx.account, ctx.project, nil, document) do
        {:ok, %{run_id: id}} ->
          {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))
          assert List.last(job_names(view)) == "deploy"
          assert has_element?(view, ~s(#jobs li[data-name="deploy"]), "Not run")

        {:error, {:invalid_workflow_run, errors}} ->
          flunk("graph document was refused: #{inspect(errors)}")
      end
    end

    test "a called run that is stored is linked from its call job, and back", ctx do
      parent = store!(ctx, goodflows("history-parent-default"))
      child = store!(ctx, goodflows("history-child-suite"))

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, parent))
      [index] = for {"call-suite", i} <- Enum.with_index(job_names(view)), do: i
      assert has_element?(view, ~s(#job-#{index}-child-link[href="#{run_path(ctx, child)}"]))

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, child))
      assert has_element?(view, ~s(#parent-link[href="#{run_path(ctx, parent)}"]))
      assert has_element?(view, "#summary-parent", "call-suite")
    end

    test "a called run or a calling run that was not uploaded is said so", ctx do
      child_of_history_parent_default = store!(ctx, goodflows("child"))
      {:ok, view, _html} = live(ctx.conn, run_path(ctx, child_of_history_parent_default))
      assert has_element?(view, "#parent-missing", "not uploaded")

      other = project_fixture(ctx.account, %{slug: "other"})
      parent = store!(ctx, goodflows("history-parent-default"), other)
      {:ok, view, _html} = live(ctx.conn, run_path(ctx, parent, "other"))

      [index] = for {"call-suite", i} <- Enum.with_index(job_names(view)), do: i
      assert has_element?(view, "#job-#{index}-child", "was not uploaded")
    end
  end

  describe "failed tests and reports" do
    defp report_run!(ctx) do
      store!(ctx, Map.merge(minimal(), %{"run_id" => @report_run}))
    end

    test "a failed test is listed under its job with file, and the retried one apart", ctx do
      report_run!(ctx)
      ack = stored_report_fixture(ctx.account, ctx.project, "failed")

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, @report_run))
      render_async(view)

      section = "#report-#{ack.id}"
      assert has_element?(view, section <> " h3", "test")
      assert has_element?(view, "#{section}-failed-0", "divides")
      assert has_element?(view, "#{section}-failed-0", "src/math.test.js")
      refute has_element?(view, "#{section}-failed-1")
      assert has_element?(view, "#{section}-retried-0", "adds")
      assert has_element?(view, ~s(#test-report-#{ack.id}), "suite-20261101-a")
    end

    defp insert_records!(ctx, report_id, records) do
      payload = report("complete") |> with_report_id(report_id) |> with_records(records)

      {1, [%{id: id}]} =
        Repo.insert_all(
          Report,
          [
            %{
              account_id: ctx.account.id,
              project_id: ctx.project.id,
              workflow_run_id: @report_run,
              workflow: "ci",
              job: "test",
              job_status: "failed",
              suite_id: "suite",
              report_id: report_id,
              status: "complete",
              payload: payload,
              payload_digest: Document.digest(payload),
              inserted_at: DateTime.utc_now()
            }
          ],
          returning: [:id]
        )

      id
    end

    defp finished(name, outcome) do
      %{
        "event" => "test_finished",
        "group" => "G",
        "path" => [],
        "name" => name,
        "duration_us" => 1,
        "outcome" => outcome
      }
    end

    test "a failed test shows its line", ctx do
      report_run!(ctx)

      report_id =
        insert_records!(ctx, "lines", [
          %{
            "event" => "test_finished",
            "group" => "GC.AlphaTest",
            "path" => [],
            "name" => "rejects bad input",
            "file" => "test/gc/alpha_test.exs",
            "line" => 42,
            "duration_us" => 1_000,
            "outcome" => "failed"
          }
        ])

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, @report_run))
      render_async(view)

      assert has_element?(view, "#report-#{report_id}-failed-0", "rejects bad input")
      assert has_element?(view, "#report-#{report_id}-failed-0", "test/gc/alpha_test.exs:42")
    end

    test "past 200 failed or retried tests, the rest are counted, not shown", ctx do
      report_run!(ctx)

      records =
        for(n <- 1..201, do: finished("failing #{n}", "failed")) ++
          for n <- 1..202, outcome <- ["failed", "passed"], do: finished("flaky #{n}", outcome)

      report_id = insert_records!(ctx, "many", records)

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, @report_run))
      render_async(view)

      assert has_element?(view, "#report-#{report_id}-failed-199", "failing 200")
      refute has_element?(view, "#report-#{report_id}-failed-200")
      assert has_element?(view, "#report-#{report_id}-more", "1 more failed test is not shown.")
      assert has_element?(view, "#report-#{report_id}-retried-199", "flaky 200")
      refute has_element?(view, "#report-#{report_id}-retried-200")

      assert has_element?(
               view,
               "#report-#{report_id}-retried-more",
               "2 more tests that passed on retry are not shown."
             )
    end

    test "a failed run without reports says none was uploaded", ctx do
      id =
        store!(
          ctx,
          Map.merge(minimal(), %{"outcome" => "failed", "results" => [result("test", "failed")]})
        )

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))
      render_async(view)

      assert has_element?(view, "#no-test-reports", "No test report was uploaded")
      assert has_element?(view, "#no-reports")
    end

    test "an incomplete report is marked next to its failed tests", ctx do
      report_run!(ctx)
      ack = stored_report_fixture(ctx.account, ctx.project, "incomplete")

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, @report_run))
      render_async(view)

      assert has_element?(view, "#report-#{ack.id}-incomplete", "Incomplete report")
      assert has_element?(view, "#report-#{ack.id}-failed-0", "first")
    end

    test "a change request whose head is the run's commit is linked", ctx do
      commit = String.duplicate("ab", 20)
      id = store!(ctx, Map.put(minimal(), "source", %{"commit" => commit}))

      {api_key, _token} = api_key_fixture(ctx.account_user, %{type: :private})

      {:ok, cr} =
        ChangeRequests.create(ctx.account, ctx.project, api_key, %{
          "title" => "Add login",
          "source_branch" => "feat/login"
        })

      {:ok, _status, cr} =
        ChangeRequests.report_git_facts(
          cr,
          api_key,
          git_facts(commit)
        )

      {:ok, view, _html} = live(ctx.conn, run_path(ctx, id))

      path = "/dashboard/accounts/#{ctx.account.id}/projects/web/change-requests/#{cr.number}"
      assert has_element?(view, ~s(#change-request-#{cr.number} a[href="#{path}"]), "Add login")
    end
  end
end
