# Spec Delta

## MODIFIED Requirements

### Requirement: Change request responses carry the record
A change request response MUST include under `data` the `id`, `number`, `title`, `state`, `source_branch`, `target_branch`, `openspec_change` (or null), `links` (or null), `head` (the last reported head, or null), `parent` (the parent change request's number, or null), `opened_by` with the opener's `user_id`, `merge` (null unless merged), `inserted_at` and `updated_at`. It MUST NOT include `account_id` or `project_id`.

#### Scenario: New change request
- **WHEN** a client creates a change request without Git facts
- **THEN** the response has `head` null, `parent` null, `merge` null, and `opened_by.user_id` equal to the key owner's user id

### Requirement: A merge report records the merge
`POST .../change-requests/:number/merged` SHALL accept only `merged_commit` (40 or 64 lowercase hex characters) and `target_branch` (1 to 256 UTF-8 bytes, no control characters), both required, and an optional `lease_id` (a string; one that names no active lease of the change request is recorded as a merge without a lease, and a non-string MUST return `422` on `lease_id`). It is accepted from `draft` or `open` and moves the change request to `merged`.

#### Scenario: Merge an open change request
- **WHEN** an `open` change request has a `mergeable` verdict and a client reports `{"merged_commit": "<40-hex>", "target_branch": "main"}`
- **THEN** the API responds `200` with `state` `merged`, `merge.verdict_state` `mergeable`, and `merge.merged_without_mergeable_verdict` false

#### Scenario: Merge a draft
- **WHEN** a client reports a merge for a `draft` change request
- **THEN** the API responds `200` with `state` `merged`

#### Scenario: Merge a closed change request
- **WHEN** a client reports a merge for a `closed` change request
- **THEN** the API responds `409` and the state stays `closed`

#### Scenario: Invalid merged commit
- **WHEN** a client reports a merge with `merged_commit` `ABC123`
- **THEN** the API responds `422` with an error on `merged_commit` and the state is unchanged

#### Scenario: Non-string lease ID
- **WHEN** a client reports a merge with `lease_id` `42`
- **THEN** the API responds `422` with an error on `lease_id` and the state is unchanged

### Requirement: The merge record keeps the verdict at merge
The response's `merge` MUST hold `merged_commit`, `target_branch`, `merged_at`, the `head`, the `verdict_state`, `policy_version` and `reasons` of the verdict at that head, `merged_without_mergeable_verdict`, and `merged_without_lease`. These values MUST NOT change after the merge is recorded.

#### Scenario: Verdict stored with the merge
- **WHEN** an `open` change request whose verdict at head `H` is `needs_review` under policy version `4` with one `one_way_door` reason is reported merged
- **THEN** `merge` has `head` `H`, `verdict_state` `needs_review`, `policy_version` `4`, and `reasons` with that `one_way_door` reason

#### Scenario: Merge record after a policy change
- **WHEN** a change request was merged under policy version `4` and an admin then writes version `5`
- **THEN** its `merge.policy_version` is still `4` and `merge.reasons` are unchanged

### Requirement: The verdict covers only the last reported head
The verdict MUST be computed for the change request's current head only. Inputs for other heads, including claims and workflow runs on earlier heads, MUST NOT affect it. There are two exceptions: a verify run on an earlier commit that counts for the head under the verify-runs rule for when a run counts for a change request, and a merge-result verify run that decides the merge-result check of the `merge-coordination` capability.

#### Scenario: Workflow passed on an earlier head
- **WHEN** `ci` passed on `H1`, the head is now `H2`, and `ci` has no run on `H2`
- **THEN** the verdict is `pending` with a `required_workflow_missing` reason whose `subject` is `["ci"]`

#### Scenario: Verify run before a docs-only commit
- **WHEN** a final clean verify run graded the approved intent digest on `H1`, and the head is now `H2`, whose only commit after `H1` changes paths matching `evidence.ignore_paths`
- **THEN** the run counts for the verdict at `H2`

#### Scenario: Merge-result run on a merge commit
- **WHEN** CR 42 at head `H` holds a lease with `base` `B`, regrading applies, and a final clean run with `merge_result` `{base: B, commit: M}` and `source.commit` `M` passes every Must of the approved intent set
- **THEN** the merge-result check passes, although `M` is not `H`

## ADDED Requirements

### Requirement: A change request may name a parent

`PUT /api/v1/projects/:project/change-requests/:number/parent` with `{"number": <n>}` SHALL set the change request's one parent and respond `200` with the change request, which shows `parent`. `DELETE` on the same path SHALL clear it and respond `200`. Both require an `sk_` key of the account (`pk_` `403`) and a child in `draft` or `open` (else `409` `not_editable`).

#### Scenario: Set a parent

- **WHEN** CR 41 and CR 42 are `open` in project `goodcases` and a client puts `{"number": 41}` to CR 42's parent route
- **THEN** the API responds `200` with `parent: 41`

#### Scenario: Replace the parent

- **WHEN** CR 42's parent is 40 and a client puts `{"number": 41}`
- **THEN** CR 42's parent is 41 and it has no other parent

#### Scenario: Clear the parent

- **WHEN** CR 42's parent is 41 and a client deletes CR 42's parent
- **THEN** the API responds `200` with `parent: null`

#### Scenario: Merged child

- **WHEN** CR 42 is `merged` and a client puts `{"number": 41}` to its parent route
- **THEN** the API responds `409` with `error: "not_editable"` and the parent is unchanged

### Requirement: A parent has a lower number in the same project

A parent SHALL be a change request of the same project with a lower number than the child. A number that names no change request of the project, or a number equal to or higher than the child's, MUST return `422` on `number`. This rule makes parent chains acyclic.

#### Scenario: Higher number

- **WHEN** a client puts `{"number": 43}` to CR 42's parent route
- **THEN** the API responds `422` with an error on `number` and the parent is unchanged

#### Scenario: Self as parent

- **WHEN** a client puts `{"number": 42}` to CR 42's parent route
- **THEN** the API responds `422` with an error on `number`

#### Scenario: Unknown number

- **WHEN** a client puts `{"number": 7}` to CR 42's parent route and project `goodcases` has no CR 7
- **THEN** the API responds `422` with an error on `number`

### Requirement: A child waits for its parent to merge

While a change request's parent is `draft` or `open`, its verdict SHALL be `pending` with a reason whose `rule` is `parent_not_merged` and whose `subject` is `[<parent number>]`. The child is still graded and reviewed, and its other reasons are kept. When the parent becomes `merged` the reason MUST be removed and the child's verdict recomputed.

#### Scenario: Parent open

- **WHEN** CR 42's parent CR 41 is `open` and CR 42's other rules would make it `mergeable`
- **THEN** CR 42's verdict is `pending` with reason `parent_not_merged` and subject `["41"]`

#### Scenario: Other reasons kept

- **WHEN** CR 42's parent is `open` and a `path_match` rule fired on CR 42
- **THEN** CR 42's verdict lists both `parent_not_merged` and the `path_match` reason

#### Scenario: Parent merges

- **WHEN** CR 41 is reported merged
- **THEN** CR 42's verdict is recomputed in the same transaction without `parent_not_merged`

### Requirement: A closed parent holds the child pending

While a change request's parent is `closed`, its verdict SHALL be `pending` with a reason whose `rule` is `parent_closed` and whose `subject` is `[<parent number>]`. Reopening the parent MUST replace it with `parent_not_merged`; clearing the parent MUST remove it.

#### Scenario: Parent closed

- **WHEN** CR 41 is closed while it is CR 42's parent
- **THEN** CR 42's verdict is `pending` with reason `parent_closed` and subject `["41"]`

#### Scenario: Parent reopened

- **WHEN** CR 41 is reopened to `open`
- **THEN** CR 42's verdict has reason `parent_not_merged` and no `parent_closed`

#### Scenario: Parent cleared

- **WHEN** CR 42's parent CR 41 is closed and a client deletes CR 42's parent
- **THEN** CR 42's verdict has neither `parent_closed` nor `parent_not_merged`

### Requirement: Retargeting a change request

`POST /api/v1/projects/:project/change-requests/:number/retarget` with `{"target_branch": "<name>"}` SHALL change the target branch of a `draft` or `open` change request and respond `200`. With a parent, only the parent's target branch is allowed (else `422` on `target_branch`) and only after the parent is `merged` (else `409` `parent_not_merged`). Without one, any branch is allowed. It requires an `sk_` key, changes no Git ref, and recomputes the verdict in the same transaction.

#### Scenario: Retarget after the parent merges

- **WHEN** CR 41 targeting `main` is `merged` and CR 42 targeting `a` with parent 41 is retargeted to `main`
- **THEN** the API responds `200` with `target_branch: "main"` and CR 42's head is unchanged

#### Scenario: Parent not merged

- **WHEN** CR 41 is `open` and a client retargets its child CR 42 to `main`
- **THEN** the API responds `409` with `error: "parent_not_merged"` and the target is unchanged

#### Scenario: Wrong branch for a child

- **WHEN** CR 41 targeting `main` is `merged` and a client retargets CR 42 to `develop`
- **THEN** the API responds `422` with an error on `target_branch`

#### Scenario: No parent

- **WHEN** CR 50 has no parent and targets `main`, and a client retargets it to `release/1.2`
- **THEN** the API responds `200` with `target_branch: "release/1.2"`

#### Scenario: Retarget while holding a merge lease

- **WHEN** CR 50 holds an active merge lease and a client retargets it
- **THEN** the API responds `409` with `error: "lease_held"` and the target is unchanged

### Requirement: A retarget whose parent link keeps changing is not editable

A retarget SHALL lock the parent before the child. When the parent link changes between reading the change request and locking it, the retarget MUST roll back and start again from a fresh read, at most three attempts in all. When the link changes under every attempt, the API SHALL respond `409` with `error: "not_editable"` and the target is unchanged.

#### Scenario: Parent set during a retarget

- **WHEN** CR 42 has a `merged` parent targeting `main`, a client retargets it to `main`, and its parent is changed to the `open` CR 43 before the retarget locks CR 42
- **THEN** the API responds `409` with `error: "parent_not_merged"` and the target is unchanged

#### Scenario: Parent changed under every attempt

- **WHEN** CR 42's parent changes before each of three attempts of a retarget locks CR 42
- **THEN** the API responds `409` with `error: "not_editable"` and the target is unchanged

### Requirement: A retarget admits new Git facts for the same head

After a retarget, the change request SHALL accept a `git-facts` report for its current head whose `target.branch` is the new target branch, under the core rule that reports are identified by head and target branch. Until it arrives, the verdict MUST be `pending` with a `git_facts_missing` reason whose `subject` is `[<head>]`, and the verdict and change request keep that `head`.

#### Scenario: New facts after retarget

- **WHEN** CR 42 at head `a1b2c3d` was retargeted from `a` to `main` and the client reports `git-facts` for `a1b2c3d` with `target.branch: "main"`
- **THEN** the API responds `201` and the verdict is computed from the new report

#### Scenario: Facts missing after retarget

- **WHEN** CR 42 at head `a1b2c3d` was retargeted to `main` and no `git-facts` for that head names `main`
- **THEN** CR 42's verdict is `pending` with a `git_facts_missing` reason with `subject` `["a1b2c3d…"]` and `head` `a1b2c3d…`

### Requirement: Answers survive a retarget at an unchanged head

A retarget SHALL NOT clear answers, scenario set approvals, or counted verify runs. Answers given at the head still count after a retarget for every review item that still exists at that head; items that are new from the new Git facts MUST need their own answers.

#### Scenario: Same items after retarget

- **WHEN** CR 42 at head `a1b2c3d` had its `one_way_door` item approved, is retargeted to `main`, and its new `git-facts` produce the same `one_way_door` item
- **THEN** that item is still approved and needs no new answer

#### Scenario: New item after retarget

- **WHEN** CR 42's new `git-facts` against `main` add a `size` reason that was not present before
- **THEN** the verdict is `needs_review` until the `size` item is answered at head `a1b2c3d`

### Requirement: A merge without a valid lease is flagged

A merge report that names no `lease_id`, or names one that is not the change request's active, unexpired lease, SHALL still be recorded, with `merge.merged_without_lease` true. A merge under a valid lease MUST have `merge.merged_without_lease` false. The flag is independent of `merge.merged_without_mergeable_verdict`.

#### Scenario: Merge after the lease expired

- **WHEN** CR 42's lease `L1` expired at `12:10:00Z` and the client reports CR 42 merged with `lease_id` `L1` at `12:12:00Z`
- **THEN** CR 42 is `merged` with `merge.merged_without_lease` true

#### Scenario: Merge with no lease

- **WHEN** a client reports CR 42 merged without `lease_id` and CR 42 never held a lease
- **THEN** CR 42 is `merged` with `merge.merged_without_lease` true

#### Scenario: Both flags

- **WHEN** a client reports CR 42 merged without a lease while its verdict is `pending` with `merge_result_ungraded`
- **THEN** CR 42 has `merge.merged_without_lease` true and `merge.merged_without_mergeable_verdict` true

#### Scenario: Retry names a lease

- **WHEN** CR 42 was merged without a lease and the same merge report is sent again with a `lease_id`
- **THEN** the API responds `200` and `merge.merged_without_lease` is still true

### Requirement: Parent and retarget routes are in the OpenAPI document

The OpenAPI document SHALL describe the parent `PUT` and `DELETE` routes, the retarget route, the change request's `parent` and `merge.merged_without_lease` fields, the merge report's optional `lease_id`, and the `403`, `404`, `409` and `422` responses of each new route.

#### Scenario: OpenAPI lists the merge report lease

- **WHEN** a client fetches the OpenAPI document
- **THEN** the merge report request schema lists an optional `lease_id` and the merge schema lists `merged_without_lease`
