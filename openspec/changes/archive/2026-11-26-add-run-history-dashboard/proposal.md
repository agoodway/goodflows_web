# Proposal

## Why

The `goodflows` CLI uploads every workflow run to the project, with its outcome, git source, CI context, per-job results and test reports. Account members can read none of it in the dashboard. A run shows up only when its commit is a change request's head, in that page's "Workflow runs at head" panel. To find out why CI failed on `main`, a member reads the raw JSON from `GET /workflow-runs/:run_id` with an API key. That document has no failed test names, because those live in separate test reports that only an `sk_` client can match up by hand. The project itself has no page: its slug on the Projects page links straight to its change requests.

## What Changes

- **Project overview** at `/dashboard/accounts/:account_id/projects/:slug`. It has two cards:
  - Runs: the latest run of each workflow on the default branch, and the 5 most recent runs.
  - Change requests: counts of active change requests by verdict, and the 5 most recently updated.
  
  The slug on the Projects page links here. The project slug in change request breadcrumbs links here too.
- **Run list** at `…/projects/:slug/runs`. It shows all runs newest first, 50 per page, with Load more.
  - Filters are kept in the URL with the API's parameter names: workflow, outcome, branch, commit (a full SHA only), environment, CI event and ticket, plus `thread_url` and `graph_sha256`, which are set through the URL (for example from a link) and shown as removable filters.
  - A failed run's row names its failed jobs.
  - A run called by another stored run is folded under its parent while no filter is active.
  - New runs appear without a reload.
- **Run detail** at `…/projects/:slug/runs/:run_id`. It shows:
  - the run's summary
  - every job, failures first, with `command`, `error` and step costs
  - the **failed tests** from the run's test reports, with tests that passed on retry shown apart as flaky
  - test report summaries
  - links to parent and child runs, and to change requests whose head is the run's commit
- **API:** workflow run list summaries gain `failed_jobs`, the names of the results that failed or timed out. Existing fields don't change.
- Every account member sees the full run, including commands, errors and thread links. This is the same view an `sk_` key gets.

## Capabilities

### New Capabilities

- `project-overview`: the project's home page in the dashboard and its Runs and Change requests cards.
- `run-history-dashboard`: the dashboard's run list and run detail pages, including failed tests from test reports and live updates.

### Modified Capabilities

- `change-request-dashboard`: the Projects page links each slug to the project overview instead of the change request list, and the project slug in the breadcrumbs links to the overview.
- `workflow-run-storage`: run summaries include `failed_jobs`.

## Impact

- **Migration on `workflow_runs`:**
  - Adds `failed_jobs text[] NOT NULL DEFAULT '{}'` and `parent_run_id uuid NULL`, plus an index on `(project_id, parent_run_id)`.
  - Backfills both columns from `payload` in batches. Runs are immutable, so each row is written once.
  - Ingest fills both columns from the validator's extracted columns.
- **New queries:**
  - `WorkflowRuns`: list options the API never sets (fold children, include child counts), runs that a parent called, distinct filter values, and the latest run per workflow on a branch.
  - `TestReports.failed_tests/3`: the first read of report contents. It runs inside Postgres.
  - `ChangeRequests`: verdict counts for the overview card.
- **Live updates:** the first insert of a run sends a `pg_notify` on a new channel. `ProjectEvents.Listener` turns it into a broadcast on a new runs topic, so every node updates its pages. The event feed and its long-poll readers don't change.
- **UI:**
  - New LiveViews `ProjectLive.Show`, `WorkflowRunLive.Index` and `WorkflowRunLive.Show`, in the `:account_scoped` live session.
  - A new `WorkflowRunComponents` module takes the run formatters out of `ChangeRequestLive.Show`.
  - `ProjectLive.Index` and both change request pages get the new links.
  - No new sidebar item.
- **API:** the `WorkflowRunSummary` OpenAPI schema gains `failed_jobs`. No request changes and no new endpoints.
- **goodflows CLI:** no companion change needed, because the change only adds a field. Checked in agoodway/goodflows at commit `fa3eb28998703429bb085c24f0fab9a89e7adb43`: `src/reporting/history_client.rs` (`page/1`, used by `history list`) reads list summaries as untyped `serde_json::Value` and checks only the keys it needs (`run_id`, `workflow`, `outcome`, `started_at`, `duration_ms`, `environment`, `source`), and `src/output/history.rs` renders only named fields. No summary type uses `deny_unknown_fields`, so an extra `failed_jobs` key is accepted.
- **Out of scope:**
  - charts, comparing runs, graph and timeline views
  - failure messages, which the test report format doesn't carry, and logs, which aren't stored
  - verify runs and Spry runs
  - short-SHA and date-range filters
  - write actions
  - masking commands by role
