# Tasks

## 1. Run events

- [x] 1.1 Add `workflow_run_stored` and `verify_run_stored` to `ProjectEvents` types, the `GoodFlowsWeb.Schemas.ProjectEvent` enum and description; verify the OpenAPI test lists both types
- [x] 1.2 Record `workflow_run_stored` per locked active change request in `recompute_for_commit/2` with the uploading key as actor (design D5); verify tests for a run on a head (one event, data fields), a run on no active head (none) and an exact retry (none)
- [x] 1.3 Record `verify_run_stored` per locked active change request in `recompute_for_scenario_digest/2` when a run becomes `final`, from both the direct-final and commit paths; verify tests for finalize (one event) and an `uploading` run (none)
- [x] 1.4 Verify the event controller test shows the new events to a `pk_` key with `actor` null and `data` as stored

## 2. Reads

- [x] 2.1 Add `WorkflowRuns.latest_clean_by_workflow/2` (design D4); verify tests for a retried workflow, a dirty newest run and a run on another commit
- [x] 2.2 Add `Grading.explain_runs/4` with the reasons in the spec's order (design D3); verify tests for each reason, an earlier commit that counts, and that its `:counts` run IDs equal `verdict.counted_runs` for the grading fixtures

## 3. Detail page

- [x] 3.1 Add the QA scenarios panel below Evidence at head: set headers (name, status badge and per-priority result badges, then a strip of labeled fields: Version, Revision for diff, Uploaded, Results from, as in the mockup), not-graded note, scenario table with names from the graded version, and decisions (design D1, D2); verify LiveView tests for graded sets, an unapproved intent set, a failed must and a rejection note
- [x] 3.2 Add the verify runs table to the panel; verify LiveView tests for `Counts`, `Dirty tree` and `Older set version`
- [x] 3.3 Add the Workflow runs at head panel with required, missing and other rows and the CI link; verify LiveView tests for the required/missing/other scenario and the CI link
- [x] 3.4 Show the frozen panels for merged and closed change requests with `Counts`/`Not counted` only; verify a LiveView test for a merged change request
- [x] 3.5 Verify live refresh tests: a non-required workflow run and a dirty verify run appear without a reload
- [x] 3.6 Render the page in both themes and at 400px wide with the verify-goodflows skill and inspect screenshots of a blocked head, an unapproved intent set and a merged change request; verify the design tests in `test/good_flows_web/design/` pass

## 4. Integration

- [x] 4.1 Run `mix precommit` in `app/` and verify it passes
