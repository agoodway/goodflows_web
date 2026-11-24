# Design

## Context

See proposal.md for motivation. The detail page (`GoodFlowsWeb.ChangeRequestLive.Show`) loads the change request, its stored verdict, the review packet and open tasks in `load/2`, and reloads 500 ms after any project event on the project's PubSub topic.

What is stored and readable today:

- `change_request_verdicts.scenarios` holds, per source, `version`, `digest`, `approved`, `graded`, `accepted` and `baseline_version` (diff), and each scenario's `id`, `priority`, `result` and `run_id`, from the newest counted run of that set (`Rules.scenarios_view/1`).
- `counted_runs` holds the counted verify run IDs; `inputs.required_workflows` maps each required workflow to the counted run's `run_id` or nil.
- Scenario names, a diff set's `revision`, and the uploader are only on `scenario_set_versions` (`front_matter`, `account_user_id`, `api_key_id`). `Version.scenarios/1` drops the name.
- `ScenarioSets.decisions/2` returns a digest's decisions with membership, channel, note and time.
- `verify_runs` has `status`, `dirty`, `merge_result`, `source_commit`, `scenario_set_source` and `scenario_set_digest` as columns; results are in `document`.
- `workflow_runs` has `workflow`, `outcome`, `started_at`, `duration_ms`, `source_commit`, `source_dirty` and `ci` as columns. Required workflow lookup is served by `workflow_runs_required_workflow_index`.
- `WorkflowRuns.ingest/4` calls `ChangeRequests.recompute_for_commit/2` in the insert transaction; `VerifyRuns` calls `recompute_for_scenario_digest/2` when a run becomes `final`. Both lock the affected active change requests.

## Goals / Non-Goals

**Goals:**
- The panels agree with the summary and the verdict reasons: they read the same stored verdict, and every "counts" mark comes from the grading rules, not from page logic.
- No migration, and no read of large `document` or `payload` columns beyond the result lists already read for grading.

**Non-Goals:**
- Showing results from runs other than the one the verdict used per set.
- Explaining why a workflow run did not count (the panel shows one clean run per workflow).

## Decisions

### D1. Scenario rows come from the verdict, names from the graded version

Rows are `verdict.scenarios[source]["scenarios"]`, in order. Names come from the version the verdict names (`ScenarioSets.get_version/3` with `verdict.scenarios[source]["version"]`, which preloads `account_user`; the page preloads `api_key` and shows the uploader's email from the account's member emails it already loads), matched by ID. Reading the current version instead could show a name from a version uploaded after the verdict; uploads recompute in the same transaction, so the two only differ for a frozen verdict, where the graded version is the right one. A scenario missing from the version's front matter (not possible today) shows its ID with no name.

The grading run's finish time and commit come from the `run_id` in the rows, looked up with the verify runs of D3, so no extra query.

### D2. "Not graded" text comes from the stored flags

`graded` false on intent means `approved` false under `require_approved_intent`; on diff it means the revision does not name the head. The page picks the message from the source; it does not re-run the rules.

### D3. Verify run explanations are a grading function

`Grading.explain_runs(change_request, facts_document, policy, grading)` returns, for up to 50 runs in the project whose `scenario_set_digest` is a digest of any of the change request's versions (newest `finished_at`, then `run_id`), each run's summary columns, result counts and a `status`: `:counts` or the first reason in the spec's order. It reuses `counts?/4`, `names_head?/4` and the loaded `grading` sets, so a run marked `:counts` is exactly one `counted_runs/4` returns. A test asserts that the explanation's `:counts` run IDs equal `verdict.counted_runs` for the fixtures in `grading_test.exs`.

The digest set is read from `scenario_set_versions` by change request. Selecting runs by digest rather than by head commit includes runs on earlier commits, which can count (D7 of the grading design). Result counts use a SQL aggregate over `document->'results'` so the documents are not loaded.

Alternative considered: compute the reasons in the LiveView from the columns. Rejected because the ignore-path and revision rules would be duplicated and drift.

For a merged or closed change request the policy, facts and approvals may have changed since the stored verdict, so `explain_runs/4` is not called. Its verify runs and non-required workflow runs are limited to those stored at or before the verdict's `computed_at`, so later runs do not appear in the frozen panels. The page lists the same runs with `Counts` when the run ID is in the stored `counted_runs`, else `Not counted`.

### D4. Workflow rows reuse the verdict's counted run

`WorkflowRuns.latest_clean_by_workflow(project, commit)` returns, with `DISTINCT ON (workflow)` ordered by `started_at DESC, run_id DESC`, the newest run per workflow at `commit` whose `source_dirty` is not true, selecting summary columns and `ci`. This is the same ordering `ChangeRequests.required_workflows/2` uses, so for an active change request the row of a required workflow is the counted run. A frozen verdict can predate later runs on its head, so for required workflows the page uses the run ID in `verdict.inputs.required_workflows` and loads that run when the query returned a different one; the panel then always agrees with the summary. Required names without a run become `Missing` rows. The commit is `verdict.head`, which is the change request head for an active one and the merged head for a frozen one.

The trigger column reads `ci.event` and `ci.attempt`, or `Local run` when `ci` is null. The link is `ci.url` only.

### D5. Run events are recorded where the recompute already locks

`recompute_for_commit/2` and `recompute_for_scenario_digest/2` take an extra argument with the run's event data and actor, and call `ProjectEvents.record/5` for each locked change request after its recompute. That keeps the documented lock order (change request rows, then the event lock) and records nothing when no active change request is affected. Exact retries never reach these functions, so they record nothing. The actor is `Review.cli_actor/1` of the uploading key.

Alternative considered: one project-level event with `number` null per run. Rejected because it wakes every long-poll reader for runs on `main`, and the page could not tell whether the run concerns it.

`workflow_run_stored` data: `run_id`, `workflow`, `outcome`, `commit`. `verify_run_stored` data: `run_id`, `commit`, `source`, `digest`. Neither has a note or ticket, so public keys see them as stored with `actor` null.

### D6. Refresh needs no page change

The page already reloads on any project event of its project. A run that also changes the verdict writes `verdict_changed` in the same transaction; the 500 ms debounce reloads once. LiveView tests send the PubSub message by hand, since the SQL sandbox never commits and `pg_notify` never fires; the end-to-end path (commit, listener, PubSub, refresh) is covered by the verify-goodflows run.

## Risks / Trade-offs

- [The verify runs table adds a query and a JSON aggregate per refresh] → It is capped at 50 rows, filtered by indexed `project_id` and digest, and the refresh is debounced to two per second per open page.
- [A shared digest across change requests lists the same runs on both] → Correct: a run grades the content, and counts for both.
- [Feed readers that switch on `type` see new values] → The feed's type list already grew in earlier changes; the OpenAPI enum and the spec list the new types.
- [Merged change requests do not refresh on later runs] → No event is recorded for them; their panels show stored state, which runs cannot change.
