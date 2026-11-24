# Spec Delta

## ADDED Requirements

### Requirement: The detail page shows each graded scenario set
Below the evidence summary, the detail page SHALL show the intent and diff sets in the verdict, each with its version, digest prefix, `Approved`/`Not approved` (intent) or `Accepted`/`Not accepted` (diff), the uploader, and the verify run its results came from. A diff set SHALL also show its revision and baseline version. A set the verdict does not grade MUST say so and why.

#### Scenario: Graded sets
- **WHEN** change request 42's verdict grades intent version 3 (approved) and diff version 2 (not accepted, baseline version 1), with results from runs `7c1d…` and `3b9e…`
- **THEN** the page shows intent version 3 as `Approved` with run `7c1d…`, and diff version 2 as `Not accepted` with baseline version 1 and run `3b9e…`

#### Scenario: Intent set not approved
- **WHEN** the policy requires an approved intent set and change request 42's current intent version is not approved
- **THEN** the intent set shows `Not graded` with a note that no verify run counts until its current version is approved

### Requirement: The detail page lists each scenario's result
For each set in the verdict, the page SHALL list every scenario in front matter order with its ID, name, priority and result. The result SHALL be the one the verdict stores, from the newest counted run of that set: `Passed`, `Failed`, `Not run`, or `No result` when the set is not graded or no counted run has the scenario.

#### Scenario: Failed must scenario
- **WHEN** diff scenario `retry-backoff` is a `must` and the verdict stores result `failed` for it
- **THEN** its row shows ID `retry-backoff`, its name, `Must` and `Failed`

#### Scenario: No counted run
- **WHEN** the intent set is graded but no counted verify run grades it
- **THEN** each of its scenarios shows `No result`

### Requirement: The detail page lists decisions on each set
For each set in the verdict, the page SHALL list the approve and reject decisions recorded on its current digest, oldest first, with who made each (member email), its channel, its time and, for a rejection, its note. A set with none SHALL say so.

#### Scenario: Rejection with a note
- **WHEN** member `ada@example.com` rejected intent version 3 in the dashboard with note `Check Retry-After`
- **THEN** the intent set lists `Rejected by ada@example.com` with channel `dashboard`, the time and the note

### Requirement: The detail page lists the change request's verify runs
The page SHALL list up to 50 of the change request's verify runs on the digests of its intent and diff set versions, newest finished first, each with its run ID prefix, set and version, commit prefix, finish time and result counts.

#### Scenario: Runs on two sets
- **WHEN** change request 42 has one final run on its intent digest and two on its diff digests
- **THEN** the page lists the three runs, newest finished first, each naming its set and version

### Requirement: The detail page explains each verify run
Each listed run MUST be marked `Counts` when the verdict counted it, or else with the first reason that applies: still uploading, dirty tree, merge-result run, older set version, intent set not approved, diff set does not name the head, no Git facts at the head, or commit does not count at the head.

#### Scenario: Dirty run
- **WHEN** a final verify run on the head grades the current diff digest from a dirty tree
- **THEN** it is listed with `Dirty tree`, not `Counts`

#### Scenario: Older set version
- **WHEN** a clean final run grades diff version 1 and the current diff version is 2
- **THEN** it is listed with `Older set version`

#### Scenario: Counted run
- **WHEN** the verdict's counted runs include run `3b9e…`
- **THEN** run `3b9e…` is listed with `Counts`

#### Scenario: Earlier commit that still counts
- **WHEN** a run on an earlier commit counts because every later commit changes only ignored paths
- **THEN** it is listed with `Counts`

### Requirement: The detail page shows the workflow runs at the head
The page SHALL list one row per workflow with a run on the verdict's head whose source is not dirty: for a required workflow, the run the verdict counted; for any other, the newest such run. Each row SHALL show the workflow, whether it is required, the outcome, start time, duration and trigger, and link to the CI run when the run has a CI URL. A required workflow the verdict found no run for MUST show `Missing`.

#### Scenario: Required and other workflows
- **WHEN** the policy requires `ci`, `e2e` and `lint`, and the head has clean runs of `ci`, `lint` and `nightly-perf`
- **THEN** the panel shows `ci` and `lint` as required with their runs, `e2e` as required and `Missing`, and `nightly-perf` as not required

#### Scenario: Retried workflow
- **WHEN** the head has a failed `ci` run and a later passed `ci` run, both clean
- **THEN** the panel shows one `ci` row, the passed run

#### Scenario: Dirty local run
- **WHEN** the newest `ci` run on the head is from a dirty tree and an older one is clean
- **THEN** the panel shows the older clean run

#### Scenario: CI link
- **WHEN** a shown run has `ci.url` `https://github.com/acme/web/actions/runs/1`
- **THEN** its row links to that URL

### Requirement: Merged and closed change requests show frozen evidence panels
For a merged or closed change request with a stored verdict, the scenario, verify run and workflow run panels SHALL show what the stored verdict saw, at the verdict's head, and MUST NOT give reasons for verify runs other than `Counts` and `Not counted`. The page MUST say that nothing updates them.

#### Scenario: Merged change request
- **WHEN** a member opens merged change request 43 whose stored verdict graded diff version 2 at head `H`
- **THEN** the panels show diff version 2's results and the workflow runs on `H`, marked as frozen

### Requirement: Evidence panels refresh on run events
While a member has the detail page open, a `workflow_run_stored` or `verify_run_stored` event for its change request SHALL refresh the panels without a reload, within 2 seconds, even when the verdict does not change.

#### Scenario: Workflow run that is not required
- **WHEN** a member has change request 46 open and a clean `nightly-perf` run on its head is stored
- **THEN** the workflow runs panel shows `nightly-perf` without the member reloading

#### Scenario: Verify run that does not count
- **WHEN** a member has change request 46 open and a dirty verify run on its current diff digest is finalized
- **THEN** the verify runs table lists it with `Dirty tree` without the member reloading
