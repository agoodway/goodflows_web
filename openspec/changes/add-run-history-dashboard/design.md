# Design

## Context

See proposal.md for why. The specs in this change define the behavior.

- **Dashboard pages.** They are LiveViews in the `:account_scoped` live session. `UserAuth` `:load_account_context` assigns `current_account`. `ChangeRequestLive.Index` and `ChangeRequestLive.Show` are the closest pages to copy: they resolve the slug with `Projects.get_project/2`, redirect on a miss, keep filters in the URL, page with Load more, and refresh 500 ms after a `{:project_event, _}` message.
- **Run storage.** `GoodFlows.WorkflowRuns` already stores and reads runs:
  - `list_runs/3` pages summary columns by `(started_at DESC, run_id DESC)`, validates every filter, and never reads `payload`.
  - `get_run/3` returns the full row and the test report summaries.
  - `ingest/4` inserts with `ON CONFLICT DO NOTHING`. Only on a first insert does it call `ChangeRequests.recompute_for_commit/3`, which records `workflow_run_stored`, and only for change requests whose head is the run's commit.
  - Columns are copied from the document by `Validator.columns/1`.
  - `parent_run_id` and the result statuses exist only inside `payload`.
- **Live notification.** `ProjectEvents.record/5` sends `pg_notify('project_events', project_id)` in the writing transaction. `ProjectEvents.Listener` holds one `Postgrex.Notifications` connection per node and turns each notification into `Phoenix.PubSub.local_broadcast` on `ProjectEvents.topic/1`.
- **Test reports.** `test_reports.payload` holds up to 100,000 records and up to 32 MiB per report. Nothing reads report contents today. `status` is the stored completeness, `complete` or `incomplete`.
- **Run formatters.** `ChangeRequestLive.Show` formats runs with private functions: `outcome_kind`, `outcome_label`, `format_duration`, `trigger`, `ci_url`, and `short`.
- **No copy control.** `CoreComponents` has no copy-to-clipboard control.

## Goals / Non-Goals

**Goals:**
- The run list and the overview never read `payload`. Their cost stays bounded by the indexes, as the API list's does.
- The run list's URL filters behave exactly like the API's, because both use the same validation.
- Failed tests are computed inside Postgres. The app never loads a report's records.
- Every node's pages update when a run is stored, whichever node stored it.

**Non-Goals:**
- Live updates on the run detail page. A stored run never changes. Test reports that arrive after the page loads appear on the next visit.
- Any new API endpoint. The API keeps listing called runs as their own rows. Folding them under their parent is a dashboard choice.
- Masking commands, errors or thread links by role.
- Caching the filter values or the failed tests.

## Decisions

### D1. Three LiveViews under the project slug

| Page | LiveView | Route |
| --- | --- | --- |
| Project overview | `ProjectLive.Show` | `/projects/:slug` |
| Run list | `WorkflowRunLive.Index` | `/projects/:slug/runs` |
| Run detail | `WorkflowRunLive.Show` | `/projects/:slug/runs/:run_id` |

- All three go in the `:account_scoped` live session with `active_nav: :projects`.
- The detail page checks `run_id` with `Validator.canonical_uuid?/1` before calling `get_run/3`. Then an uppercase id is a `Run not found` redirect and is never looked up, as the API does.
- The pages are named for workflow runs, not plain "runs", so they don't collide with the Spry `runs` table.

Alternative considered: tabs on one project page. Rejected because each list already has its own filters, paging and URL. Tabs would hold three pages' state in one LiveView.

### D2. One migration adds `failed_jobs` and `parent_run_id`, then backfills them

**New columns:**
- `failed_jobs text[] NOT NULL DEFAULT '{}'`
- `parent_run_id uuid NULL`
- an index `workflow_runs_parent_index` on `(project_id, parent_run_id) WHERE parent_run_id IS NOT NULL`

A constant default is a catalog-only change, so adding the columns rewrites no rows.

**On ingest,** `Validator.columns/1` also returns:
- `failed_jobs`: each result `name` whose status is `failed` or `timed_out`, in result order
- `parent_run_id`: copied from the document

`failed_jobs` is a summary field. `parent_run_id` is not; the list uses it only to fold called runs.

**The backfill** is a second migration with `@disable_ddl_transaction true` and `@disable_migration_lock true`. It updates rows in batches of 1,000 by `id`, one transaction per batch:

- `failed_jobs`, for rows with `outcome = 'failed'`: `ARRAY(SELECT r->>'name' FROM jsonb_array_elements(payload->'results') WITH ORDINALITY AS t(r, i) WHERE r->>'status' IN ('failed','timed_out') ORDER BY i)`
- `parent_run_id`, for rows where `payload ? 'parent_run_id'`: `(payload->>'parent_run_id')::uuid`

The validator already requires a failed outcome to have a failed or timed-out result, and only failed runs have one. So the `outcome = 'failed'` condition finds every row that needs `failed_jobs`. Runs are immutable, so each row is written once and the backfill can be rerun safely.

Alternatives considered:
- Computing `failed_jobs` from `payload` at read time. Rejected because the list would read `payload` on every row, which the storage spec rules out for list cost.
- A `has_children` flag on the parent. Rejected because a child can be stored before its parent, so the flag would need an update to an immutable row.

### D3. Folding called runs is a list option the API never sets

`list_runs/3` becomes `list_runs/4` with dashboard-only options, the same approach `ChangeRequests.list/3` took:

- **`fold_children: true`** adds this condition:

  ```sql
  r.parent_run_id IS NULL
  OR NOT EXISTS (
    SELECT 1 FROM workflow_runs p
    WHERE p.account_id = r.account_id AND p.project_id = r.project_id
      AND p.run_id = r.parent_run_id)
  ```

  The identity index serves the subquery. The keyset order and the cursor don't change, so Load more behaves as it does today.
- **`WorkflowRuns.children(project, parent_run_ids)`** returns the summaries of runs that the page's runs called. It uses the parent index, in one query per page, and the rows show a count from it.
- The LiveView passes `fold_children: true` only when no filter is active (the spec's "Called runs fold under their parent"). The overview's recent runs pass it too.

A child whose parent is missing still shows as its own row. The row says the parent wasn't uploaded when `parent_run_id` is set and that run isn't stored. The page checks this with `summaries/2` for the page's parent ids.

### D4. Live updates use a second notification channel

On a first insert, `insert_or_compare/2` runs `SELECT pg_notify('workflow_runs', project_id || ':' || run_id)` in the insert's transaction. An exact retry takes the `compare` branch and sends nothing.

`ProjectEvents.Listener` listens on both channels, over the same connection. It broadcasts `{:workflow_run_stored, project_id, run_id}` on a new topic, `WorkflowRuns.topic(project_id)`. Postgres delivers the notification only on commit, so pages never hear about a run that rolled back. Every node receives it.

Each page handles the message the same way the change request list does (D4 of the change request dashboard design):
1. It schedules one `:refresh` 500 ms later and ignores further messages until the refresh runs.
2. The run list reloads the rows it already shows, plus any new ones. It makes one `list_runs/4` call with the current filters and a `limit` equal to the rows loaded plus one. The limit is capped at 200, then later pages load as before.
3. Rows are streamed with `reset: true` and keyed by `run_id`, so a run never appears twice and the order is always the list order.
4. The overview reruns its D6 queries.

The overview also subscribes to `ProjectEvents.topic/1` for change request changes.

Alternatives considered:
- Recording a `workflow_run_stored` event for every run. Rejected because the feed is change request activity: long-poll readers would wake up for runs that no change request cares about, and the 90-day feed would grow with every CI run.
- `Phoenix.PubSub.broadcast/3` after commit. Rejected because the app's PubSub reaches other nodes only when they are clustered, and the listener pattern already works without clustering.

### D5. Failed tests come from one SQL query per run

`TestReports.failed_tests(account, project, run_id)` runs one query, with `log: false` and the test report database timeout, over the run's reports:

1. Expand `payload->'report'->'records'` with `jsonb_array_elements(...) WITH ORDINALITY` and keep `event = 'test_finished'`.
2. Partition by report and the test key `(group, path, name)`. The final execution is the record with the highest ordinality. A test is **failed** when its final outcome is `failed` or `errored`. It **passed on retry** when its final outcome is `passed` and an earlier execution failed or errored.
3. Number the failed tests per report by ordinality. Return the first 200 per report and the total per report.

It returns, for each report:
- its summary fields
- `failed`: each test's group, path, name, file, line, duration and outcome
- `failed_total`
- `retried`: the tests that passed on retry

The detail page loads the results with `start_async`, so the summary and jobs render first, and the section shows a loading state until the query returns.

Alternatives considered:
- `jsonb_path_query` alone. Rejected because it can't number records, and step 2 needs the order of executions.
- Extracting failed tests into a table at ingest. Kept as the fallback if task 5.1's measurement is too slow. It would need its own backfill.

### D6. Overview queries

**Default branch health.** `WorkflowRuns.latest_by_workflow_on_branch(project, branch)`:

```sql
SELECT DISTINCT ON (workflow) <summary columns>
FROM workflow_runs
WHERE account_id = $1 AND project_id = $2 AND source_branch = $3
ORDER BY workflow, started_at DESC, run_id DESC
```

- It uses the branch list index.
- It doesn't filter dirty runs, unlike `latest_clean_by_workflow/3`. Its "clean only" rule exists for verdicts.

**Recent runs.** `list_runs/4` with `limit: 5` and `fold_children: true`.

**Change requests.**
- `ChangeRequests.verdict_counts(project)` groups the `draft` and `open` change requests by `coalesce(verdict.state, 'pending')`.
- `ChangeRequests.recent_active(project, 5)` orders them by `updated_at DESC` and preloads the verdict.

### D7. Filter controls use the API's validation

- The URL query goes into `list_runs/4` as given. A filter that fails validation returns its changeset error on that field. The page shows the error under the matching control and lists without that filter. Only invalid filters are dropped; the others stay applied.
- The commit field accepts only what `Validator.valid_commit?/1` accepts: 40 or 64 lowercase hex characters.
- The page reads its select values once, on mount, with `WorkflowRuns.filter_values(project)`:
  - the distinct workflows and environments, using the workflow index
  - the distinct branches among the newest 500 runs
- The copyable API query is built from the active, valid filters, in a fixed order: the order of the API's parameter list.

### D8. Shared components

- `GoodFlowsWeb.WorkflowRunComponents` takes the run formatters out of `ChangeRequestLive.Show` and adds a row component. Its functions:
  - `outcome_badge/1`, `job_status_badge/1`
  - `duration/1`, `trigger/1`, `short_sha/1`
  - `failed_jobs/1`, which shows up to 3 names and then `+N more`
  - `run_row/1`

  The overview, both run pages and the change request panel use them.
- `CoreComponents` gains `copy_button/1` with a colocated hook that calls `navigator.clipboard.writeText`. It shows a copied state and has an accessible label. It copies run ids, commits, test file paths and the API query.

This follows DESIGN.md's rule: a control used in a second place becomes a shared component.

### D9. The JSON summary adds `failed_jobs`

- `WorkflowRunJSON` adds `failed_jobs` to each list summary. The `WorkflowRunSummary` OpenAPI schema gains it as an array of strings, always present.
- The show response keeps its shape: its `document` already carries the results.
- `pk_` keys see `failed_jobs`, because job names are already public in the `pk_` view of a document.

## Risks / Trade-offs

- **The failed-tests query detoasts every report of the run on each detail visit.** A run with 3 partitions of 30 MiB reads about 90 MiB inside Postgres.
  → It runs async with the report timeout, so a slow query shows an error in that section only. Task 5.1 measures it on the largest fixture scaled to 100,000 records. If it is too slow, the fallback in D5 applies.
- **The backfill touches every failed or called run once.** It runs batched and outside a transaction, so it can run while uploads continue: new rows already carry both columns.
- **`DISTINCT ON (workflow)` scans the default branch's whole history.** That is fine for thousands of runs per branch.
  → If EXPLAIN on a project with 50,000 `main` runs shows a slow plan, switch to a `LATERAL` lookup per workflow on the workflow index.
- **Child folding adds an anti-join to the default list.** It is one index probe per row on a page of 51, so it is cheap.
- **Every member sees commands, errors and thread links.** This is an explicit v1 decision ("for now"). The detail page is the only place that reads `payload`, so a later masking rule has one place to go.
- **A refresh reloads every loaded row.** A member who loaded 500 rows reloads them on each new run, at most twice a second. The change request list made the same trade-off.

## Migration Plan

1. Deploy the schema migration, then the backfill migration, then the code. `GoodFlows.Release.migrate/0` runs both before the new code starts.
2. Between the two migrations, rows stored by the old code have empty `failed_jobs` and a null `parent_run_id`. The backfill fills them, because it selects by `outcome` and `payload`, not by an empty column.
3. Rollback: roll back the code only. As with the `links` migration, the columns stay in production. Dropping them would lose nothing, because they can be rebuilt from `payload`, but rebuilding needs the backfill again.
