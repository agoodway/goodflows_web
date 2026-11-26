## Purpose

Gives account members a per-project history of the workflow runs the `goodflows` CLI uploads, with filters that match the API, and a detail page that shows why a run failed: its failed jobs and their errors, and the failed tests from its test reports.

## ADDED Requirements

### Requirement: Run pages are scoped to the account's projects
The dashboard SHALL serve a run list at `/dashboard/accounts/:account_id/projects/:slug/runs` and a run detail page at `/dashboard/accounts/:account_id/projects/:slug/runs/:run_id`. Both MUST require a signed-in member of the account; every member, whatever their role, SHALL see them. Both pages write nothing.

#### Scenario: Member opens the run list
- **WHEN** a signed-in member with role `member` opens the run list of project `web` in their account
- **THEN** the page shows `web`'s workflow runs

### Requirement: Unknown projects and runs redirect
A slug that names no project of the account MUST redirect to the account's Projects page with the flash `Project not found`. A `run_id` that is not a lowercase canonical UUID, or names no run of the project, MUST redirect to the project's run list with the flash `Run not found`. Neither MUST show another account's or project's data.

#### Scenario: Run of another project
- **WHEN** run X is stored under project `a` and a member opens run X under project `b` of the same account
- **THEN** they are redirected to `b`'s run list with the flash `Run not found`

#### Scenario: Uppercase run id
- **WHEN** a member opens a stored run's detail page with its `run_id` in uppercase
- **THEN** they are redirected to the run list with the flash `Run not found`

### Requirement: Run pages show navigation context
The run pages SHALL keep the Projects item active in the sidebar. The breadcrumbs SHALL be Dashboard, Projects, the project slug (linking to the project overview), Runs and, on the detail page, the first 8 characters of the `run_id`.

#### Scenario: Detail breadcrumbs
- **WHEN** a member opens run `0e54fb55-a115-4ac7-80fe-8fde26e76afb` of project `web`
- **THEN** the breadcrumbs read Dashboard, Projects, `web`, Runs, `0e54fb55`, and `web` links to the project overview

### Requirement: The run list pages newest first
The run list SHALL show the project's runs by `started_at` descending, then `run_id` descending, 50 per page, with a Load more button while more exist. With no filter it SHALL show runs from every branch.

#### Scenario: More than one page
- **WHEN** a project has 51 runs and a member presses Load more
- **THEN** the list shows all 51 and the Load more button is gone

### Requirement: The run list filters match the API
The run list SHALL accept the filters `workflow`, `outcome`, `branch`, `commit`, `environment`, `event`, `ticket`, `thread_url` and `graph_sha256` with the meaning and validation of the workflow run list API, combined with AND, and MUST keep them in the URL query under those names. Each active filter SHALL be shown and removable on its own. An invalid filter value MUST NOT be applied and SHALL show an error naming that filter.

#### Scenario: Filter in the URL
- **WHEN** a member opens the run list with `?workflow=ci&outcome=failed`
- **THEN** only failed runs of workflow `ci` are listed and both filters are shown as active

#### Scenario: Short commit
- **WHEN** a member enters the commit `5a4a971`
- **THEN** the filter is not applied and the page says the commit must be a full 40- or 64-character SHA

#### Scenario: Remove one filter
- **WHEN** the list has filters `workflow=ci` and `branch=main` and the member removes the branch filter
- **THEN** the URL is `?workflow=ci` and runs of `ci` from every branch are listed

### Requirement: The run list offers the API query
The run list SHALL show the `GET /api/v1/projects/:slug/workflow-runs` request with the current filters as a copyable URL.

#### Scenario: Copy the query
- **WHEN** the list has the filters `branch=main` and `outcome=failed`
- **THEN** the copyable query is `/api/v1/projects/web/workflow-runs?branch=main&outcome=failed` for project `web`

### Requirement: Run rows show the comparison fields
Each row SHALL show the outcome, workflow, environment when present, branch when present, the first 7 characters of the commit with a mark when the source was dirty, the trigger (`ci.event` with `ci.pull_request` when present, or `local` without `ci`), a link to `ci.url` when present, the start time and the duration, and SHALL link to the run's detail page. Clicking the workflow, branch or commit SHALL apply that filter.

#### Scenario: Pull request run
- **WHEN** a run has `ci` `{"provider": "github_actions", "event": "pull_request", "pull_request": 42, "url": "https://github.com/a/b/actions/runs/1"}`
- **THEN** its row shows the trigger `pull_request #42` and links to that URL

#### Scenario: Local run
- **WHEN** a run has no `ci` and no `source`
- **THEN** its row shows the trigger `local` and no branch or commit

### Requirement: Failed rows name their failed jobs
A row of a run with outcome `failed` SHALL name the results whose status is `failed` or `timed_out`, in result order, at most 3, followed by `+N more` when there are more.

#### Scenario: Many failed jobs
- **WHEN** a failed run has failed results `test`, `lint`, `format`, `credo` and `dialyzer` in that order
- **THEN** its row shows `test`, `lint`, `format` and `+2 more`

### Requirement: Called runs fold under their parent
With no filter active, the run list MUST NOT list a run as its own row when its `parent_run_id` names a run stored in the same project. That parent's row SHALL show how many of its called runs are stored and SHALL expand to show them. A run whose parent is not stored SHALL be listed as its own row and marked as called by a run that was not uploaded. With any filter active, matching called runs SHALL be listed as their own rows.

#### Scenario: Stored parent
- **WHEN** run P is stored and run C has `parent_run_id` P and `caller_job` `call-suite`
- **THEN** the unfiltered list has no row for C, P's row says it calls 1 run, and expanding it shows C

#### Scenario: Missing parent
- **WHEN** run C has `parent_run_id` Q and no run Q is stored
- **THEN** the unfiltered list has a row for C marked as called by a run that was not uploaded

#### Scenario: Filter by the called workflow
- **WHEN** run C of workflow `suite` is folded under its parent and a member filters by `workflow=suite`
- **THEN** C is listed as its own row

### Requirement: The run list has empty states
A project with no runs SHALL show an empty state that explains how to upload a run with the `goodflows` CLI and links to the account's API keys page. Filters that match nothing SHALL show an empty state naming the active filters with a control that clears them.

#### Scenario: No matches
- **WHEN** a member filters by `branch=nope` and no run has that branch
- **THEN** the page says no run matches `branch` `nope` and offers to clear the filters

### Requirement: The run list updates live
When a run of the project is stored, the run list SHALL show it without a reload if it matches the active filters, keeping the filters and every loaded row. A run stored again as an exact retry MUST NOT be shown twice.

#### Scenario: New run while filtered
- **WHEN** a member has the list open with `?workflow=ci` and runs of `ci` and `lint` are uploaded
- **THEN** the `ci` run appears at the top and the `lint` run does not

### Requirement: The detail page summarizes the run
The detail page SHALL show the run's outcome, workflow, full `run_id`, start time, duration, environment, full commit and dirty flag, branch, CI context with a link to `ci.url`, host, parallelism, max in flight, `graph_sha256`, requested jobs, ticket and thread links, and the time it was stored. Absent optional fields SHALL be left out. It SHALL show every field to every member, including thread links.

#### Scenario: Minimal run
- **WHEN** a member opens a run stored with only the required keys
- **THEN** the page shows its outcome, workflow, timing and host, and no source, CI or links rows

### Requirement: The detail page lists every job
The detail page SHALL list every result with its status, name, partition as `i/n` when present, duration, queued and blocked time and exit code, failed and timed-out results first by default, with a control to show result order. Each result SHALL reveal its `command`, `error` and per-step costs. A graph job with no result SHALL be listed as not run.

#### Scenario: Failure first
- **WHEN** a run has results `compile` passed, `test` failed and `lint` passed in that order
- **THEN** the jobs list starts with `test`, and the result-order control shows `compile`, `test`, `lint`

#### Scenario: Job error
- **WHEN** result `test` has `exit_code` 2 and `error` `mix test exited with 2`
- **THEN** the page shows exit code 2 and that error for `test`

#### Scenario: Graph job without a result
- **WHEN** the graph has jobs `compile` and `deploy` and the results have only `compile`
- **THEN** `deploy` is listed as not run

### Requirement: The detail page links called and calling runs
A result with `child_run_id` SHALL link to that run's detail page when it is stored and say the called run was not uploaded otherwise. A run with `parent_run_id` SHALL link to its parent's detail page with the `caller_job`, or say the parent was not uploaded.

#### Scenario: Called run stored
- **WHEN** result `call-suite` has `workflow` `suite` and a stored `child_run_id` C
- **THEN** `call-suite` links to C's detail page

### Requirement: The detail page shows failed tests
The detail page SHALL list, for each test report of the run, the tests whose final execution failed or errored, grouped by report job and partition, each with its group, path, name, file, line, duration and outcome. A test that failed or errored and later passed in the same report SHALL be listed apart as passed on retry and MUST NOT count as failed. Each report SHALL list at most 200 failed tests and say how many more there are.

#### Scenario: Failed test
- **WHEN** a report for job `test` has a `test_finished` for `GC.AlphaTest` `rejects bad input` in `test/gc/alpha_test.exs` line 42 with outcome `failed`
- **THEN** the page lists that test under `test` with its file and line

#### Scenario: Passed on retry
- **WHEN** a report has two executions of the same group, path and name, the first `failed` and the second `passed`
- **THEN** that test is listed as passed on retry and not as failed

#### Scenario: Run without reports
- **WHEN** a failed run has no test reports
- **THEN** the page says no test report was uploaded for the run

### Requirement: Failed tests mark incomplete reports
A report whose stored status is `incomplete` SHALL be marked as incomplete next to its failed tests, so a short list is not read as the full result.

#### Scenario: Interrupted report
- **WHEN** a report was stored as `incomplete` and has 1 failed test
- **THEN** the page lists that test and marks the report as incomplete

### Requirement: The detail page lists test reports and related change requests
The detail page SHALL list each test report of the run with its job, job status, suite, partition and completeness, and SHALL link every change request of the project whose head is the run's commit.

#### Scenario: Run at a change request head
- **WHEN** change request 42's head is the run's commit
- **THEN** the page links to change request 42
