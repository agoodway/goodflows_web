defmodule GoodFlowsWeb.TestReportLive.ShowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures
  import GoodFlows.WorkflowRunFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.WorkflowRuns

  @run_id "67f7946d-136b-4608-ab01-e1f251a09754"

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    account_user_fixture(account, user, :member)
    project = project_fixture(account, %{slug: "web", default_branch: "main"})
    %{account: account, project: project}
  end

  defp run_path(ctx), do: "/dashboard/accounts/#{ctx.account.id}/projects/web/runs/#{@run_id}"
  defp report_path(ctx, id, query \\ ""), do: "#{run_path(ctx)}/reports/#{id}#{query}"

  defp selected(outcome),
    do: ~s(#filter-chip-outcome [data-selected="#{outcome}"][aria-selected="true"])

  test "the run page links each report to its page", ctx do
    {:ok, _} =
      WorkflowRuns.ingest(ctx.account, ctx.project, nil, Map.put(minimal(), "run_id", @run_id))

    ack = stored_report_fixture(ctx.account, ctx.project, "failed")
    {:ok, view, _html} = live(ctx.conn, run_path(ctx))
    render_async(view)

    assert has_element?(view, ~s(#test-report-#{ack.id}-link[href="#{report_path(ctx, ack.id)}"]))
    assert has_element?(view, ~s(#report-#{ack.id}-link[href="#{report_path(ctx, ack.id)}"]))

    {:ok, report_view, _html} =
      view
      |> element("#test-report-#{ack.id}-link")
      |> render_click()
      |> follow_redirect(ctx.conn)

    assert has_element?(report_view, "#report-job", "test")
  end

  test "a report with failures opens filtered to them; All shows every test", ctx do
    ack = stored_report_fixture(ctx.account, ctx.project, "failed")
    {:ok, view, _html} = live(ctx.conn, report_path(ctx, ack.id))

    assert has_element?(view, selected("failed"))
    assert has_element?(view, "#test-0", "divides")
    refute has_element?(view, "#test-1")
    assert has_element?(view, "#groups", "src/broken.test.js")

    view
    |> element("#select-opt-outcome-1")
    |> render_hook("select_option_value", %{"id" => "outcome", "selected" => "all"})

    assert_patch(view, report_path(ctx, ack.id, "?outcome=all"))
    assert has_element?(view, "#test-0-retried", "Passed on retry")
    assert has_element?(view, "#test-0-attempts li", "invocations: 2")
    assert has_element?(view, "#test-1", "divides")
  end

  test "a report without failures shows every test; search narrows the list", ctx do
    ack = stored_report_fixture(ctx.account, ctx.project, "complete")
    {:ok, view, _html} = live(ctx.conn, report_path(ctx, ack.id))

    assert has_element?(view, selected("all"))
    assert has_element?(view, "#test-3")

    view |> element("#always-on-q") |> render_change(%{"filter" => %{"q" => "no such test"}})
    assert_patch(view, report_path(ctx, ack.id, "?outcome=all&q=no+such+test"))
    assert has_element?(view, "#no-tests", "No test matches the search.")
  end

  test "an incomplete report warns that it stopped early", ctx do
    ack = stored_report_fixture(ctx.account, ctx.project, "incomplete")
    {:ok, view, _html} = live(ctx.conn, report_path(ctx, ack.id))

    assert has_element?(view, "#warning-incomplete")
    assert has_element?(view, "#warning-interrupted")
    assert has_element?(view, "#warning-max-failures")
  end

  test "a report of another project, or a bad id, redirects to the run", ctx do
    other = project_fixture(ctx.account)
    ack = stored_report_fixture(ctx.account, other, "failed")
    run = run_path(ctx)

    for id <- [ack.id, "nope"] do
      assert {:error, {:live_redirect, %{to: ^run, flash: %{"error" => "Test report not found"}}}} =
               live(ctx.conn, report_path(ctx, id))
    end
  end
end
