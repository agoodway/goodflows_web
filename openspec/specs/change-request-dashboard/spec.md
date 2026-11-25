# change-request-dashboard Specification

## Purpose

Gives account members a change request list and detail page per project in the dashboard, showing each change request's verdict and why, its review packet, evidence, merge status and history, kept current by project events, and lets members answer review items there under the same rules as the API.

## Requirements

### Requirement: Change request pages are scoped to the account's projects
The dashboard SHALL serve a change request list at `/dashboard/accounts/:account_id/projects/:slug/change-requests` and a detail page at `/dashboard/accounts/:account_id/projects/:slug/change-requests/:number`. Both MUST require a signed-in user who is a member of the account; every member, whatever their role, SHALL see them.

#### Scenario: Member opens the list
- **WHEN** a signed-in member with role `member` opens the change request list of project `web` in their account
- **THEN** the page shows `web`'s change requests

### Requirement: Unknown projects and change requests redirect
A slug that names no project of the account, a number that names no change request of the project, or a number that is not a positive integer MUST redirect to the account's Projects page with the error flash `Change request not found` or `Project not found`, and MUST NOT show another account's data.

#### Scenario: Project of another account
- **WHEN** a signed-in user opens the change request list with their own account ID and the slug of a project that belongs only to another account
- **THEN** they are redirected to their account's Projects page with the flash `Project not found`

#### Scenario: Unknown number
- **WHEN** a member opens change request 999 of a project that has 3 change requests
- **THEN** they are redirected to the account's Projects page with the flash `Change request not found`

### Requirement: Change request pages are reached from the Projects page
The Projects page SHALL link each project's slug to its change request list. The pages SHALL keep the Projects item active in the sidebar and show the breadcrumbs Dashboard, Projects, the project slug, Change requests and, on the detail page, `#<number>`.

#### Scenario: Projects page links to the list
- **WHEN** a member views the Projects page
- **THEN** each project slug links to that project's change request list

### Requirement: The list pages and filters change requests
The list SHALL show the project's change requests by `number` descending, 50 per page, with a Load more button while more exist. A filter SHALL select Active (state `draft` or `open`, the default), Merged, Closed or All, and the filter MUST be kept in the URL as `?state=active|merged|closed|all`. Each row SHALL link to the change request's detail page. When the filter matches nothing, the page SHALL show an empty state naming the filter.

#### Scenario: Default filter
- **WHEN** a project has change requests 41 (closed), 44 (merged), 45 (open) and 47 (draft) and a member opens the list
- **THEN** the rows are 47 then 45

#### Scenario: More than one page
- **WHEN** a project has 51 active change requests and a member presses Load more
- **THEN** the list shows all 51, and the Load more button is gone

#### Scenario: Filter in the URL
- **WHEN** a member opens the list with `?state=closed`
- **THEN** the Closed filter is selected and only closed change requests are listed

### Requirement: The list shows change requests with their verdicts
Each row SHALL show the number, title, source and target branch, the state when it is not `open`, the verdict state, the review count as `<cleared> of <items>`, and the update time as `YYYY-MM-DD HH:MM UTC`. A closed change request SHALL show no verdict. A change request with no stored verdict SHALL show `Pending` and `0 of 0`.

#### Scenario: Review count
- **WHEN** change request 45's stored verdict has `review` `{"items": 4, "cleared": 2}`
- **THEN** its row shows `2 of 4`

### Requirement: Merged rows show the verdict at merge
For a merged change request the verdict SHALL be the verdict state at merge, and the row MUST say `Merged without a mergeable verdict` when the merge report says so.

#### Scenario: Verdict of a merged change request
- **WHEN** change request 43 was merged while its verdict was `blocked`, and its stored verdict was later recomputed
- **THEN** with the Merged filter its row shows `Blocked` and `Merged without a mergeable verdict`

### Requirement: The detail page shows the change request and its verdict
The detail page SHALL show the change request's number, title, state, verdict state, source branch, target branch and head (the first 7 characters, or `No head yet` when it has none). It SHALL show the verdict's policy version and computed time. A change request with no stored verdict MUST say that the verdict has not been computed.

#### Scenario: No head yet
- **WHEN** a member opens a change request that has no head
- **THEN** the page shows `No head yet` as its head

### Requirement: The detail page explains the verdict
The detail page SHALL list every reason of the stored verdict in stored order, each with its outcome, message, rule and subject (the subject is left out when it is empty). With no reasons it MUST say that no rule fired at the head. A merged change request SHALL show the reasons stored with the merge report, not the stored verdict.

#### Scenario: Needs review
- **WHEN** change request 46's verdict is `needs_review` with reasons `one_way_door` (subject `[]`) and `path_match` (subject `["priv/repo/migrations/**"]`)
- **THEN** the page shows `Needs review`, the message `The claims call this change a one-way door` with rule `one_way_door` and no subject, and the message `The diff touches paths matching priv/repo/migrations/**` with rule `path_match` and subject `priv/repo/migrations/**`

#### Scenario: Mergeable with no reasons
- **WHEN** change request 46's verdict is `mergeable` with no reasons
- **THEN** the page shows `Mergeable` and says that no rule fired at the head

### Requirement: The detail page shows the review packet
For a change request in state `draft` or `open`, the detail page SHALL show the review packet at the current head: each item's kind as a readable name, its message, and its current answer at the head with who gave it, when, and the option and note. An item with no answer at the head MUST say so. The page MUST NOT show answers given at other heads. A merged or closed change request SHALL show no review items.

#### Scenario: Answered and unanswered items
- **WHEN** change request 46 has a `one_way_door` item approved by member T at the current head and a `sensitive_path` item with no answer at the head
- **THEN** the page shows `1 of 2 cleared`, the one-way door item as approved by T with the time, and the sensitive path item as having no answer at this head

#### Scenario: Answer at an earlier head
- **WHEN** an item was approved at head `a1b2c3d…` and head `d4e5f6a…` is now current
- **THEN** the item shows no answer at this head

### Requirement: The detail page shows the review count and open tasks
For a change request in state `draft` or `open`, the detail page SHALL show the number of items cleared of the total, and every `open` task of the change request with its item, answer, note and creator.

#### Scenario: Open task
- **WHEN** change request 46 has an `open` task created by a `request_change` answer with note `split it`
- **THEN** the page lists the task with its item, the answer, the note `split it` and who created it

### Requirement: The detail page shows evidence
The detail page SHALL show:
- each of the policy's required workflows, with `passed`, `failed` or `missing` at the head
- the intent and diff scenario sets the verdict graded, with version and approval
- the verify run IDs the verdict counted
- a claims summary: door, and the number of safe-because claims, questions and open risks
- the opener, the linked change, and the parent change request linked to its detail page

#### Scenario: Missing required workflow
- **WHEN** the policy requires workflow `ci` and the verdict has a `required_workflow_missing` reason with subject `["ci"]`
- **THEN** the evidence shows `ci` as `missing`

### Requirement: The detail page shows merge status
For an active change request, the merge status SHALL show the lease held on it (holding key name and expiry) or `No lease held`. For a merged change request it SHALL show the merged commit, target branch, merge time, the verdict state at merge, and `Merged without a lease` when the report says so. When `merged_without_mergeable_verdict` is true, the page MUST show a warning notice naming the verdict state at merge.

#### Scenario: Merged without a mergeable verdict
- **WHEN** change request 43 was reported merged while its verdict was `needs_review`, without a lease
- **THEN** the page shows a warning that it was merged without a mergeable verdict, with `Needs review` as the verdict at merge, and shows `Merged without a lease`

#### Scenario: Held lease
- **WHEN** change request 46 is mergeable and key `ci-merge` holds an active lease on it
- **THEN** the merge status names `ci-merge` and the lease's expiry time

### Requirement: The detail page shows the state history
The page SHALL list the state history oldest first, with each transition, who made it, and when.

#### Scenario: Draft marked ready
- **WHEN** change request 46 was opened as a draft and then marked ready
- **THEN** the history lists the move from `draft` to `open` with who made it and when, after the opening

### Requirement: Pages update on project events
While a member has a change request page open, a committed project event for that project SHALL refresh the page without a reload, within 2 seconds of the event. A refresh MUST keep the list's filter, the rows already loaded, and an answer dialog the member has open.

#### Scenario: Verdict changes while open
- **WHEN** a member has change request 46 open and a verify run moves its verdict from `needs_review` to `mergeable`
- **THEN** the page shows `Mergeable` without the member reloading

#### Scenario: Reasons change while the state holds
- **WHEN** a member has change request 46 open with reasons `one_way_door` and `should_not_run`, and a verify run clears `should_not_run`
- **THEN** the page shows only the `one_way_door` reason without the member reloading

#### Scenario: Retarget while open
- **WHEN** a member has change request 46 open and it is retargeted from `main` to `release/2`
- **THEN** the page shows target `release/2` without the member reloading

#### Scenario: Task completed while open
- **WHEN** a member has change request 46 open with one open task, and the author agent completes it
- **THEN** the page no longer lists the task, without the member reloading

### Requirement: Members answer review items in the dashboard
On the detail page of a change request in state `draft` or `open`, each review item SHALL offer the answers its kind allows: Approve, Reject, Request change, and Choose with one of the question's options. Each answer SHALL open a dialog whose confirm button carries the answer's name. The note field is required for Reject and Request change and optional otherwise, at most 10,000 UTF-8 bytes.

#### Scenario: Request change needs a note
- **WHEN** member M confirms Request change with an empty note
- **THEN** the dialog shows an error under the note field and nothing is stored

#### Scenario: Choose an option
- **WHEN** a question item has options `keep` and `drop` and M chooses `drop`
- **THEN** the stored answer is `choose` with option `drop`

### Requirement: Dashboard answers have the API's effects
A confirmed answer SHALL be stored for the head the page showed, by the signed-in member's membership, with the same effects as an API answer: it replaces the item's earlier answer at the head, makes that answer's open task stale, creates a task for Reject and Request change, records scenario set decisions for `scenario_set_approval` and `diff_set_weakened`, records events, and recomputes the verdict. The page SHALL then show the new answer and verdict.

#### Scenario: Approve an item
- **WHEN** member M approves change request 46's `one_way_door` item from the dashboard
- **THEN** the item shows as approved by M, the cleared count rises by one, and the stored answer has M's membership and the head the page showed

### Requirement: Dashboard answers follow the API's rules
The dashboard MUST apply the API's rules on who may answer: any member may answer an item, except that `scenario_set_approval` and `diff_set_weakened` follow the policy's `scenarios.approver`. When the signed-in member may not answer an item, the item MUST show no answer actions and SHALL say who may answer it (`Another member must approve this set` or `An owner or admin must approve this set`).

#### Scenario: Author under other_member
- **WHEN** `scenarios.approver` is `other_member` and the member who opened change request 46 views its `scenario_set_approval` item
- **THEN** the item shows no answer actions and says that another member must approve the set

### Requirement: Dashboard answers need the shown head and an active change request
When the change request's head changed after the page was rendered, a confirmed answer MUST store nothing; the page SHALL show the error flash `A new head was reported. Review the items at the new head.` and show the new packet. A merged or closed change request MUST offer no answer actions.

#### Scenario: Head moved while the dialog was open
- **WHEN** member M opens the Approve dialog at head `a1b2c3d…`, head `d4e5f6a…` is then reported, and M confirms
- **THEN** no answer is stored, the flash says a new head was reported, and the page shows the packet at `d4e5f6a…`

#### Scenario: Merged change request
- **WHEN** a member views merged change request 44
- **THEN** no item offers answer actions

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
