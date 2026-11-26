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

**The backfill** is a second migration with `@disable_ddl_transaction true` and `@disable_migration_lock true`. It calls `GoodFlows.WorkflowRuns.Backfill.run/1`, which the post-deploy release task also runs (see Migration Plan). It updates rows in batches of 1,000 by `id`, one transaction per batch:

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
2. The run list reloads the rows it already shows, plus any new ones. It calls `list_runs/4` with the current filters in pages of at most 200 rows, as `ChangeRequestLive.Index.fetch_rows/4` does, until it has read the rows loaded plus one and reached the last row it had loaded before. So a member with more than 200 rows loses none, and several runs stored before one refresh never push a loaded row out. Later pages load with Load more as before.
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
3. Number the failed tests, and separately the tests that passed on retry, per report by ordinality. Return the first 200 of each per report and the total of each per report.

It returns, for each report:
- its summary fields
- `failed`: each test's group, path, name, file, line, duration and outcome
- `failed_total`
- `retried`: the tests that passed on retry, at most 200
- `retried_total`

The detail page loads the results with `start_async`, so the summary and jobs render first, and the section shows a loading state until the query returns.

Alternatives considered:
- `jsonb_path_query` alone. Rejected because it can't number records, and step 2 needs the order of executions.
- Extracting failed tests into a table at ingest. Kept as the fallback if task 5.1's measurement is too slow. It would need its own backfill.

### D6. Overview queries

**Default branch health.** `WorkflowRuns.latest_by_workflow_on_branch(project, branch)`:

```sql
WITH RECURSIVE w(workflow) AS (
  (SELECT workflow FROM workflow_runs
   WHERE account_id = $1 AND project_id = $2 ORDER BY workflow LIMIT 1)
  UNION ALL
  SELECT (SELECT r.workflow FROM workflow_runs r
          WHERE r.account_id = $1 AND r.project_id = $2 AND r.workflow > w.workflow
          ORDER BY r.workflow LIMIT 1)
  FROM w WHERE w.workflow IS NOT NULL
)
SELECT l.* FROM w CROSS JOIN LATERAL (
  SELECT <summary columns> FROM workflow_runs r
  WHERE r.account_id = $1 AND r.project_id = $2 AND r.workflow = w.workflow
    AND r.source_branch = $3
  ORDER BY r.started_at DESC, r.run_id DESC
  LIMIT 1
) l
WHERE w.workflow IS NOT NULL
ORDER BY l.workflow
```

- A recursive skip scan finds the project's workflows, then one `LIMIT 1` lookup per workflow finds its newest run on the branch.
- A separate migration adds `workflow_runs_workflow_branch_index` on `(account_id, project_id, workflow, source_branch, started_at DESC, run_id DESC)`, built `CONCURRENTLY` (with `@disable_ddl_transaction` and `@disable_migration_lock`) so uploads continue while it builds. With it, each lookup is one index-only probe, even for a workflow that never runs on the branch. Without it, the lookup walked `workflow_runs_workflow_list_index` and read the workflow's heap rows until it found one on the branch, so a workflow that ran only on pull requests cost its whole history on every overview load.
- The first draft used `SELECT DISTINCT ON (workflow) … ORDER BY workflow, started_at DESC, run_id DESC`. Task 3.2's EXPLAIN on 50,000 `main` runs showed it sorts every run of the branch on disk (145 ms) while this query takes 3.4 ms. See Measurements.
- It doesn't filter dirty runs, unlike `latest_clean_by_workflow/3`. Its "clean only" rule exists for verdicts.

**Recent runs.** `list_runs/4` with `limit: 5` and `fold_children: true`.

**Change requests.**
- `ChangeRequests.verdict_counts(project)` groups the `draft` and `open` change requests by `coalesce(verdict.state, 'pending')`.
- `ChangeRequests.recent_active(project, 5)` orders them by `updated_at DESC` and preloads the verdict.

### D7. Filter controls use the API's validation

- The URL query goes into `list_runs/4` as given. A filter that fails validation returns its changeset error on that field. The page shows the error under the matching control and lists without that filter. Only invalid filters are dropped; the others stay applied.
- The commit field accepts only what `Validator.valid_commit?/1` accepts: 40 or 64 lowercase hex characters.
- The page reads its select values once, on mount, with `WorkflowRuns.filter_values(project)`:
  - the distinct workflows, with the same recursive skip scan as D6
  - the distinct environments and branches among the newest 500 runs, from the list index
- So its cost does not grow with the project's history. An environment that only older runs used is not offered, but it can still be typed into the URL, and the select keeps the current value.
- The copyable API query is built from the active, valid filters, sorted by parameter name (`?branch=main&outcome=failed`).

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
- **The branch health query probes once per workflow.** Its cost grows with the number of workflows in the project, not with the branch's history. Each probe is one lookup on `workflow_runs_workflow_branch_index`, also for a workflow that never ran on the default branch.
- **The branch index costs one more btree insert per stored run.** Runs are written once and never updated, so it adds no update cost.
- **Child folding adds an anti-join to the default list.** It is one index probe per row on a page of 51, so it is cheap.
- **Every member sees commands, errors and thread links.** This is an explicit v1 decision ("for now"). The detail page is the only place that reads `payload`, so a later masking rule has one place to go.
- **A refresh reloads every loaded row.** A member who loaded 500 rows reloads them on each new run, at most twice a second. The change request list made the same trade-off.

## Measurements

Taken on the dev database (local PostgreSQL) while implementing the change.

**Task 3.2: branch health query.** One project with 50,000 runs on `main` and 5,000 on 50 feature branches, 8 workflows, ANALYZEd.

| Query | Plan | Execution |
| --- | --- | --- |
| `DISTINCT ON (workflow)` (first draft) | Seq scan of 50,000 rows, then an external merge sort on disk (3,632 kB) | 145.4 ms |
| Skip scan + `LATERAL … LIMIT 1` (shipped) | Index-only skip scan over `workflow_runs_workflow_list_index`, 8 index lookups | 3.4 ms |

On the same data: `latest_by_workflow_on_branch/2` 15 ms (8 rows), `list_runs/4` with `fold_children` and limit 51 28 ms, `filter_values/1` 47 ms (8 workflows, 50 branches).

**Review fixes: branch index and filter values.** One project with the data above plus a `pr-checks` workflow with 100,000 runs on feature branches and none on `main` (155,000 runs, 9 workflows, 3 environments), ANALYZEd, rolled back afterwards. "Before" drops `workflow_runs_workflow_branch_index` and runs the old `filter_values/1` queries.

| Query | Before | After |
| --- | --- | --- |
| Branch health SQL (EXPLAIN ANALYZE) | 43.3 ms: each probe walked `workflow_runs_workflow_list_index` and filtered on `source_branch`, 11,667 rows removed per probe on average | 0.3 ms: one index-only lookup per workflow on `workflow_runs_workflow_branch_index` |
| Probe for `pr-checks` on `main` alone | 16.3 ms, 50,000 rows filtered | 0.03 ms, index-only, 0 heap fetches |
| `latest_by_workflow_on_branch/2` (best of 5) | 27.1 ms | 1.1 ms |
| `filter_values/1` workflows | 35.6 ms, parallel seq scan of 155,000 rows | 0.2 ms, index-only skip scan |
| `filter_values/1` environments | 32.6 ms, parallel seq scan | 0.4 ms, newest 500 rows by the list index |
| `filter_values/1` (best of 5) | 51.8 ms | 2.9 ms |

**Task 5.1: `failed_tests/3`.** One report scaled to 100,000 records (49,999 test executions; every 20th test fails, every 50th fails then passes on retry), 31 MB of JSON, 2.0 MB stored after TOAST compression. Measured on the shipped query, which caps both the failed and the passed-on-retry tests at 200 per report (each call returned 200 of 2,000 failed and 200 of 999 retried). Five calls: 253 to 404 ms. With names padded to 51 MB of JSON, above the 32 MiB body limit: 335 to 416 ms. Both are under the approver's 2 s limit, so D5 stays as designed and the fallback is not needed.

**Task 10.2: validation.** `mix precommit` exited 0: credo `--strict` found no issues, doctor passed, sobelow was clean, dialyzer reported 0 errors, and 1,827 tests had 0 failures. `goodflows run ci --jobs test` (goodflows 0.9.0) succeeded with outcome `passed`; `mix test --include slow` took 54.7 s (run `605dd358-df9f-4250-ba4c-9b7ca9bf9a6a`).

## Migration Plan

1. Deploy the schema migration, the backfill migration and the branch index migration, then the code. `GoodFlows.Release.migrate/0` runs all three (the Fly release command) before the new code starts.
2. While the migrations run and until the new code serves, the old code keeps storing rows with empty `failed_jobs` and a null `parent_run_id`. The backfill migration walks rows in ascending `id` order, and ids are random, so it misses rows stored behind its cursor or after its last batch.
3. After the deploy finishes and the new code is serving (it fills both columns on ingest), run the backfill once more: `fly ssh console -C /app/bin/backfill_workflow_runs` on Fly, or `/app/bin/backfill_workflow_runs` in the container elsewhere. It calls `GoodFlows.Release.backfill_workflow_runs/0`, which runs `GoodFlows.WorkflowRuns.Backfill.run/1`, the same idempotent backfill the migration runs, in batches outside a transaction, so uploads continue. It selects by `outcome` and `payload`, not by an empty column, so it fills every row the first pass missed and rewrites the others to the same values. No row can be missed after it, because the new code stores both columns. Until it runs, an affected failed run lists no failed jobs and an affected called run is not folded under its parent.
4. The branch index migration builds `CONCURRENTLY`. If the build fails, PostgreSQL leaves an invalid index; drop it and run the migration again.
5. Rollback: roll back the code only. As with the `links` migration, the columns stay in production. Dropping them would lose nothing, because they can be rebuilt from `payload`, but rebuilding needs the backfill again.
