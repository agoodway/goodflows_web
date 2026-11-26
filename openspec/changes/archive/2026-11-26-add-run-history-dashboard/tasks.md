# Tasks

## 1. Run columns: `failed_jobs` and `parent_run_id`

- [x] 1.1 Add the schema migration from design D2: `failed_jobs`, `parent_run_id`, and the partial index `workflow_runs_parent_index`. Add both fields to `WorkflowRuns.Run`. Verify that `mix ecto.migrate` and `mix ecto.rollback` both run in dev.
- [x] 1.2 Extend `Validator.columns/1` to return `failed_jobs` and `parent_run_id`, and add `failed_jobs` to `@summary_fields`. Verify with tests in `workflow_runs_test.exs`:
  - results `compile` passed, `test` failed, `lint` timed_out and `deploy` cancelled store `failed_jobs` `["test", "lint"]`
  - two failed partitions of `test` store `["test", "test"]`
  - the `child.json` fixture stores its `parent_run_id`, and `minimal.json` stores null
- [x] 1.3 Add the batched backfill migration from design D2. Verify with a migration test: insert rows with `Repo.insert_all` and empty columns (a failed run, a passed run, a child run), run the backfill twice, and check that only the failed and child rows changed and that both runs give the same result.
- [x] 1.4 Review repair: add the post-deploy release task `GoodFlows.Release.backfill_workflow_runs/0` and `bin/backfill_workflow_runs`, which rerun the same backfill (`GoodFlows.WorkflowRuns.Backfill.run/1`) once the new code is serving (design Migration Plan). Verified by the migration test "the release task fills a legacy row stored after the migration ran".

## 2. API: `failed_jobs` in list summaries

- [x] 2.1 Add `failed_jobs` to `WorkflowRunJSON.summary/1` and the `WorkflowRunSummary` OpenAPI schema (design D9). Verify with `workflow_run_controller_test.exs`:
  - the spec's "Failed jobs" and "Passed run" scenarios
  - a `pk_` key sees `failed_jobs`
  - `openapi_test.exs` passes
- [x] 2.2 Verify that every vendored goodflows fixture still uploads and round-trips (`workflow_run_contract_test.exs` passes unchanged).
- [x] 2.3 Verify that `latest_clean_by_workflow/3` and `summaries/2` return `failed_jobs`, so the change request panel can use it, with one assertion in the existing reads test.
- [x] 2.4 In agoodway/goodflows, check that the CLI's workflow run history commands parse list summaries without rejecting unknown fields, for example no `deny_unknown_fields` on the summary type. Record the file and commit checked in the proposal's Impact section. If the CLI would reject the new field, stop and raise it before shipping 2.1.

## 3. Queries for the pages

- [x] 3.1 Add `list_runs/4` with `fold_children: true` and `WorkflowRuns.children/2` (design D3). Keep `list_runs/3` delegating with no options, so the API is unchanged. Verify with context tests:
  - parent P with stored child C: the folded list has no C, and `children` returns C for P
  - a child whose parent isn't stored is listed
  - paging with `limit=2` over 3 unfolded runs and 1 folded child repeats and skips nothing
  - the unfolded API list still returns C
- [x] 3.2 Add `WorkflowRuns.latest_by_workflow_on_branch/2` and `filter_values/1` (design D6, D7). Verify with a context test for the spec's "Latest run per workflow" scenario, the LiveView test `project_live/show_test.exs` "the latest run of each workflow on the default branch, dirty or not" for the "Dirty run counts" scenario, and a context test that `filter_values` lists each workflow once. Check EXPLAIN on 50,000 seeded `main` runs and record the plan in the PR (this run opened no PR, so it is in design.md, Measurements).
- [x] 3.3 Add `ChangeRequests.verdict_counts/1`, `recent_active/2`, and a lookup of the change requests whose `head` is a given commit. Verify with context tests for the spec's "Verdict counts" scenario, ordering by `updated_at`, and the head lookup ignoring other projects.
- [x] 3.4 Review repair: add `workflow_runs_workflow_branch_index` on `(account_id, project_id, workflow, source_branch, started_at DESC, run_id DESC)` in its own `concurrently: true` migration, and take `filter_values/1`'s workflows by skip scan and its environments from the newest 500 runs (design D6, D7). Verified by `create_workflow_runs_migration_test.exs` and by EXPLAIN on 155,000 seeded runs: branch health 43.3 ms → 0.3 ms, `filter_values/1` 51.8 ms → 2.9 ms (design.md, Measurements).

## 4. Live notification for stored runs

- [x] 4.1 Send `pg_notify('workflow_runs', ...)` on a first insert only, and add `WorkflowRuns.topic/1`. Make `ProjectEvents.Listener` listen on the second channel and broadcast `{:workflow_run_stored, project_id, run_id}` (design D4). Verify with tests:
  - a subscriber to the topic receives the message after an upload
  - an exact retry sends nothing
  - an upload that rolls back sends nothing, for example a stubbed failure in `Store.transaction`
  - the existing event feed tests pass unchanged

## 5. Failed tests

- [x] 5.1 Add `TestReports.failed_tests/3` (design D5). Verify with context tests built on `failed.json` and new fixture records:
  - a failed test returns its group, path, name, file, line and outcome
  - a test that failed and then passed is in `retried` and not in `failed`
  - a test that passed and then failed is in `failed`
  - 201 failed tests return 200 with `failed_total` 201
  - reports of another project or run are excluded
  
  Then time the query on a 100,000-record report and record the result in the PR (this run opened no PR, so it is in design.md, Measurements). If it takes more than 2 s, stop and raise the D5 fallback before building the page.

## 6. Shared components

- [x] 6.1 Create `GoodFlowsWeb.WorkflowRunComponents` (design D8), move the formatters out of `ChangeRequestLive.Show`, and switch its workflow runs panel to them. Verify that `change_request_live_test.exs` passes unchanged.
- [x] 6.2 Add `copy_button/1` to `CoreComponents`, with a colocated hook. Verify that a LiveView test finds the button with its value and label, and that the design guards in `test/good_flows_web/design/` pass.

## 7. Run list page

- [x] 7.1 Add `WorkflowRunLive.Index` at `/projects/:slug/runs`, with breadcrumbs, the not-found redirect, 50 rows per page with Load more, and the empty states. Verify with LiveView tests for the spec's "Member opens the run list", "More than one page", "No matches" and project-of-another-account scenarios.
- [x] 7.2 Add the URL filters, the active filter chips, the select values, per-field errors and the copyable API query (design D7). Verify with LiveView tests for the spec's "Filter in the URL", "Short commit", "Remove one filter" and "Copy the query" scenarios, and that clicking a row's branch applies `branch`.
- [x] 7.3 Render rows with `run_row/1`: trigger, CI link, dirty mark, failed jobs, and called runs folded with an expand control. Verify with LiveView tests for the spec's "Pull request run", "Local run", "Many failed jobs", "Stored parent", "Missing parent" and "Filter by the called workflow" scenarios.
- [x] 7.4 Subscribe to `WorkflowRuns.topic/1` and refresh as in design D4. Verify with LiveView tests for the spec's "New run while filtered" scenario, that 51 loaded rows stay loaded after a refresh, and that an exact retry adds no row.

## 8. Run detail page

- [x] 8.1 Add `WorkflowRunLive.Show` at `/projects/:slug/runs/:run_id`, with breadcrumbs and the summary panel. Verify with LiveView tests for the spec's "Detail breadcrumbs", "Run of another project", "Uppercase run id" and "Minimal run" scenarios, and that `full.json` shows its CI link, host and thread links.
- [x] 8.2 Add the jobs list: failures first, a result-order control, command, error and step costs, graph jobs with no result, and links to called and calling runs. Verify with LiveView tests for the spec's "Failure first", "Job error", "Graph job without a result" and "Called run stored" scenarios, using `history-parent-default.json` and `history-child-suite.json`.
- [x] 8.3 Add the failed tests section with `start_async`, the incomplete-report mark, test report summaries and related change requests. Verify with LiveView tests for the spec's "Failed test", "Passed on retry", "Run without reports", "Interrupted report" and "Run at a change request head" scenarios.

## 9. Project overview and navigation

- [x] 9.1 Add `ProjectLive.Show` at `/projects/:slug` with the Runs and Change requests cards (design D6), the empty state, and live refresh on both topics. Verify with LiveView tests for every scenario in the `project-overview` spec.
- [x] 9.2 Link each slug on the Projects page to the overview, link the slug breadcrumb on both change request pages to the overview, and link each row of the change request workflow runs panel to its run. Verify with `project_live_test.exs` and `change_request_live_test.exs` for the `change-request-dashboard` delta scenarios.

## 10. Finish

- [x] 10.1 Inspect the overview, run list and run detail in the browser in light and dark, at desktop width and at 400px:
  - a failed run with long job names and a long error
  - a run with 200+ failed tests
  - the folded child rows
  - the empty states
  
  Check keyboard focus on filters, chips, expand controls and copy buttons.
- [x] 10.2 Run `mix precommit` and `goodflows run ci --jobs test`.

## Workflow follow-up

- Archive the change after review, then confirm that `openspec/specs/project-overview` and `openspec/specs/run-history-dashboard` exist and that the `change-request-dashboard` and `workflow-run-storage` specs contain the modified requirements.
