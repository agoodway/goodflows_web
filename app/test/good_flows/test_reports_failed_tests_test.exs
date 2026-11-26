defmodule GoodFlows.TestReportsFailedTestsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures

  alias GoodFlows.TestReports
  alias GoodFlows.TestReports.{Document, Report}

  @run_id "67f7946d-136b-4608-ab01-e1f251a09754"
  @other_run "0e54fb55-a115-4ac7-80fe-8fde26e76afb"

  setup do
    account = account_fixture()
    other = account_fixture()

    %{
      account: account,
      project: project_fixture(account),
      other: other,
      other_project: project_fixture(other)
    }
  end

  defp finished(group, name, outcome, extra \\ %{}) do
    Map.merge(
      %{
        "event" => "test_finished",
        "group" => group,
        "path" => [],
        "name" => name,
        "file" => "test/#{group}.exs",
        "line" => 1,
        "duration_us" => 10,
        "outcome" => outcome
      },
      extra
    )
  end

  defp insert_report!(project, report_id, records, attrs \\ %{}) do
    payload =
      report("failed")
      |> with_report_id(report_id)
      |> with_records(records)
      |> Map.merge(Map.get(attrs, :payload, %{}))

    Repo.insert_all(Report, [
      %{
        account_id: project.account_id,
        project_id: project.id,
        workflow_run_id: Map.get(attrs, :run_id, @run_id),
        workflow: "default",
        job: Map.get(attrs, :job, "test"),
        job_status: "failed",
        suite_id: "suite",
        report_id: report_id,
        status: Map.get(attrs, :status, "complete"),
        payload: payload,
        payload_digest: Document.digest(payload),
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  test "failed.json: the failed test with its fields, the retried one apart", ctx do
    stored_report_fixture(ctx.account, ctx.project, "failed")

    assert [%{report: report, failed: [failed], failed_total: 1, retried: [retried]}] =
             TestReports.failed_tests(ctx.account, ctx.project, @run_id)

    assert {report.job, report.report_id, report.partition, report.status} ==
             {"test", "report-2", "2", "complete"}

    assert failed == %{
             group: "src/math.test.js",
             path: ["math"],
             name: "divides",
             file: "src/math.test.js",
             line: nil,
             duration_us: failed.duration_us,
             outcome: "failed"
           }

    assert {retried.name, retried.path, retried.outcome} == {"adds", ["math", "sum"], "passed"}
  end

  test "a test that passed and then failed is failed; same name in another group counts apart",
       ctx do
    insert_report!(ctx.project, "r1", [
      finished("A", "flaky", "passed"),
      finished("A", "flaky", "errored", %{"line" => 42}),
      finished("B", "flaky", "passed")
    ])

    assert [%{failed: [failed], failed_total: 1, retried: []}] =
             TestReports.failed_tests(ctx.account, ctx.project, @run_id)

    assert {failed.group, failed.name, failed.line, failed.outcome} ==
             {"A", "flaky", 42, "errored"}
  end

  test "201 failed tests return the first 200 and a total of 201", ctx do
    records = for n <- 1..201, do: finished("G", "t#{n}", "failed")
    insert_report!(ctx.project, "big", records)

    assert [%{failed: failed, failed_total: 201}] =
             TestReports.failed_tests(ctx.account, ctx.project, @run_id)

    assert length(failed) == 200
    assert hd(failed).name == "t1"
    assert List.last(failed).name == "t200"
  end

  test "201 tests that passed on retry return the first 200 and a total of 201", ctx do
    records =
      for n <- 1..201,
          outcome <- ["failed", "passed"],
          do: finished("G", "t#{n}", outcome)

    insert_report!(ctx.project, "flaky", records)

    assert [%{failed: [], failed_total: 0, retried: retried, retried_total: 201}] =
             TestReports.failed_tests(ctx.account, ctx.project, @run_id)

    assert length(retried) == 200
    assert hd(retried).name == "t1"
    assert List.last(retried).name == "t200"
  end

  test "each report is returned, ordered by job, with no failures when all passed", ctx do
    insert_report!(ctx.project, "r-test", [finished("A", "x", "failed")], %{job: "test"})

    insert_report!(ctx.project, "r-e2e", [finished("A", "y", "passed")], %{
      job: "e2e",
      status: "incomplete"
    })

    assert [e2e, test] = TestReports.failed_tests(ctx.account, ctx.project, @run_id)

    assert {e2e.report.job, e2e.report.status, e2e.failed, e2e.failed_total} ==
             {"e2e", "incomplete", [], 0}

    assert {test.report.job, Enum.map(test.failed, & &1.name)} == {"test", ["x"]}
  end

  test "reports of another run, project or account are excluded", ctx do
    insert_report!(ctx.project, "other-run", [finished("A", "x", "failed")], %{
      run_id: @other_run
    })

    insert_report!(project_fixture(ctx.account), "other-project", [finished("A", "x", "failed")])
    insert_report!(ctx.other_project, "other-account", [finished("A", "x", "failed")])

    assert TestReports.failed_tests(ctx.account, ctx.project, @run_id) == []
    assert TestReports.failed_tests(ctx.account, ctx.other_project, @run_id) == []
    assert TestReports.failed_tests(ctx.account, ctx.project, String.upcase(@other_run)) == []

    assert [%{report: %{report_id: "other-run"}}] =
             TestReports.failed_tests(ctx.account, ctx.project, @other_run)
  end
end
