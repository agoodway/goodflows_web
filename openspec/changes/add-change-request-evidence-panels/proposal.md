# Proposal

## Why

The change request detail page summarizes the evidence at the head but does not show it. A reviewer sees that a set is "not approved" or that a required workflow is "failed", and must use the CLI or API to learn which scenario failed, which run graded it, or which workflow run counted. The verdict already stores each scenario's ID, priority, result and grading run, and every workflow and verify run at the head is stored, so the page can show them without new data. A verify run that grading ignores is invisible today: the verdict only says no counted run grades the set, and the person who uploaded it cannot see why.

## What Changes

- The detail page keeps the "Evidence at head" panel as the summary and adds two panels below it.
- **QA scenarios panel.** For the intent and diff sets the verdict graded: a header with version, digest, approved or accepted, whether the set is graded (and why not), the diff set's revision and baseline version, the uploader, and the verify run its results came from. Then a table of each scenario's ID, name, priority and result in that run, and the decisions recorded on the set's digest. Results come from the newest counted run of each set, the run grading uses.
- **Verify runs table** inside the QA scenarios panel: the change request's verify runs on its sets' digests, newest first, each marked `Counts` or with the reason grading ignores it (still uploading, dirty tree, merge-result run, older set version, intent set not approved, diff set does not name the head, no Git facts at the head, or a commit that does not count at the head).
- **Workflow runs at head panel.** One row per workflow with a clean run on the head: the run the verdict counted for a required workflow, else the newest clean run. Each row shows outcome, start time, duration, trigger (CI event and attempt, or local), and a link to the CI run when the run has a `ci.url`. A required workflow with no run shows `Missing`.
- **Two new project event types**, `workflow_run_stored` and `verify_run_stored`, recorded for each `draft` or `open` change request a stored run concerns, so the panels refresh live when a run arrives that does not change the verdict.
- Merged and closed change requests show the same panels from the stored verdict, at the verdict's head, marked as frozen.
- Out of scope: failure details (failed step, reason), artifact downloads, set version history and compare, workflow jobs and test reports, run detail pages, and anything from `add-change-request-iteration-history` (reason spans, head kinds, fix counts).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `change-request-dashboard`: the detail page shows the QA scenarios, verify runs and workflow runs panels, and refreshes on the new run events.
- `project-events`: the feed gains `workflow_run_stored` and `verify_run_stored`, recorded with the run's storage and listed in the OpenAPI document.

## Impact

- `GoodFlowsWeb.ChangeRequestLive.Show` and its tests: two new panels; the Evidence at head panel is unchanged.
- `GoodFlows.ChangeRequests.Grading`: a function that explains, for one verify run, whether it counts at the head and why not, from the same rules `counted_runs/4` uses.
- `GoodFlows.WorkflowRuns`: a read of the newest clean run of each workflow on a commit, from copied columns only.
- `GoodFlows.ChangeRequests.recompute_for_commit/2` and `recompute_for_scenario_digest/2` (or their callers in `WorkflowRuns` and `VerifyRuns`) record the run events in the transaction that stores the run.
- `GoodFlows.ProjectEvents` type list, `GoodFlowsWeb.Schemas.ProjectEvent` enum and description, and the project-events spec. Feed clients that switch on `type` see two new values; the goodflows CLI prints events without matching on type.
- No migration. No change to existing API responses.
- Coordination: `add-change-request-iteration-history` changes recompute, Git facts and merge code, not the detail page. Both touch `recompute_for_commit/2`'s module; whichever lands second rebases.
