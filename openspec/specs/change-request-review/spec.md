# change-request-review Specification

## Purpose

Shows a person only what a change request's review policy flagged at its current head, with the evidence next to each item, records their answers bound to that head, and turns answers that ask for changes into tasks the author agent works through.

## Requirements

### Requirement: The review packet requires a private key
`GET /api/v1/projects/:project/change-requests/:number/review` SHALL require a valid `sk_` key of the project's account. Missing, expired or revoked keys MUST return `401`. `pk_` and `ck_` keys MUST return `403` and get no packet data. An invalid project slug returns `422` on `project`; an unknown project, including another account's, or an unknown `number` returns `404`. A request whose `Accept` does not allow `application/json` MUST return `406`.

#### Scenario: Private key reads the packet
- **WHEN** a client with an `sk_` key reads the packet of change request 42
- **THEN** the API responds `200` with the packet for change request 42's current head

#### Scenario: Public key gets no packet
- **WHEN** a client with a `pk_` key reads the packet of change request 42
- **THEN** the API responds `403` and the body contains no item, reason, claim or artifact URL

#### Scenario: Unknown change request
- **WHEN** a client with an `sk_` key reads the packet of change request 999 in a project with 3 change requests
- **THEN** the API responds `404`

### Requirement: The packet describes the current head
The packet SHALL return `data` with `number`, `head`, `base` (`branch`, `merge_base`), `policy_version`, `verdict` (the verdict state at the head), `passed`, `pending`, `blocked`, and `items`. `head` and `base` MUST be null when no `git-facts` report exists. `passed` MUST hold `must`, `should` (scenarios passed in counted runs) and `workflows` (required workflows passed on the head). The packet MUST come from the stored verdict at the current head and policy version.

#### Scenario: Header of a packet
- **WHEN** change request 42 has head `a1b2c3d…`, merge base `9f8e7d6…` on `main`, policy version 7, 6 Must and 2 Should scenarios passed and `ci` passed
- **THEN** the packet has `head` `a1b2c3d…`, `base` `{"branch": "main", "merge_base": "9f8e7d6…"}`, `policy_version` `7`, and `passed` `{"must": 6, "should": 2, "workflows": ["ci"]}`

#### Scenario: No facts reported yet
- **WHEN** change request 43 has no `git-facts` report
- **THEN** the packet has `head` null, `base` null, `verdict` `pending`, an empty `items` list, and a `pending` entry with rule `git_facts_missing`

#### Scenario: Intent set to approve before code
- **WHEN** change request 42 links an OpenSpec change, has no `git-facts` report, `scenarios.require_approved_intent` is `true`, and its current intent version has unapproved digest `5e1c…`
- **THEN** the packet has `head` null, `base` null, `verdict` `pending`, a `pending` entry with rule `git_facts_missing`, and exactly one item, of kind `scenario_set_approval` with subject `["5e1c…"]` and `answer` null

#### Scenario: Mergeable change request
- **WHEN** change request 44's verdict is `mergeable` with no reasons
- **THEN** the packet has `verdict` `mergeable` and empty `items`, `pending` and `blocked` lists

### Requirement: Pending and blocked reasons are context only
Every `pending` and `blocked` reason of the verdict SHALL appear in the packet's `pending` or `blocked` list with its `rule`, `subject` and `message`. These entries MUST NOT be items, MUST NOT carry an `id` or allowed answers, and MUST NOT be answerable. The one exception is a `scenario_set_approval` reason whose `subject` names a digest (an intent version exists): it SHALL be an item although its outcome is `pending`. With `subject` `[]` it stays in the `pending` list.

#### Scenario: Missing workflow run
- **WHEN** change request 42 has no run of required workflow `ci` on its head
- **THEN** the packet's `pending` list has an entry with rule `required_workflow_missing` and subject `["ci"]`, and no item refers to it

#### Scenario: Failed Must scenario
- **WHEN** a counted run failed Must scenario `S3` of the intent set
- **THEN** the packet's `blocked` list has a `must_failed` entry with subject `["intent", "S3"]` and no item for `S3` exists

#### Scenario: No intent set yet
- **WHEN** change request 42 links an OpenSpec change, has no intent set, and `scenarios.require_approved_intent` is `true`
- **THEN** the packet's `pending` list has a `scenario_set_approval` entry with subject `[]` and no `scenario_set_approval` item exists

#### Scenario: Unapproved intent set
- **WHEN** change request 42's current intent set version is not approved and `scenarios.require_approved_intent` is `true`
- **THEN** the packet has a `scenario_set_approval` item, and the `pending` list does not repeat that reason

### Requirement: One item per reason that needs a person
The packet SHALL hold one item per `needs_review` reason of the verdict, plus the `scenario_set_approval` item above. An `open_items` reason SHALL be split into one `question` item per claims question and one `open_item` item per `left_open` entry; every other reason gives exactly one item. Each item MUST have `id`, `kind`, `rule`, `subject`, `message`, `data`, `answers` (the answer kinds it allows) and `answer` (the current answer at the head, or null).

#### Scenario: Three items
- **WHEN** the verdict at the head has an unapproved intent set, `door: one_way` with `claims.one_way_door` `needs_review`, and one Should failure with `scenarios.should_failures` `needs_review`
- **THEN** the packet has exactly 3 items with kinds `scenario_set_approval`, `one_way_door` and `failed_scenario`

#### Scenario: Questions and open risks split
- **WHEN** the claims at the head have 2 `questions` and 1 `left_open` entry and `claims.open_items` is `needs_review`
- **THEN** the packet has 2 `question` items and 1 `open_item` item

#### Scenario: Both size limits exceeded
- **WHEN** the diff exceeds both `size.max_changed_files` and `size.max_changed_lines` under the default policy
- **THEN** the packet has two `size` items, one with rule `max_changed_files` and one with rule `max_changed_lines`

### Requirement: Each kind comes from fixed rules
Each item kind SHALL come only from fixed reasons. `scenario_set_approval`, `diff_only_set`, `diff_set_weakened`, `spec_gap`, `one_way_door`, `unmapped_area` and `undriven_feature` come from the rule of the same name; `failed_scenario` from `should_failed`; `not_run` from `should_not_run`; `unproven_claim` from `proof_below_minimum`; `question` and `open_item` from `open_items`; `sensitive_path` from `path_match`; `size` from `max_changed_files` or `max_changed_lines`.

#### Scenario: Spec gap item
- **WHEN** `scenarios.spec_gaps` is `needs_review` and the graded intent set has a `no_check` row
- **THEN** the packet has a `spec_gap` item with rule `spec_gap`

#### Scenario: Weakened diff set item
- **WHEN** the verdict has `diff_set_weakened` reasons for `S3` and `S5`
- **THEN** the packet has two `diff_set_weakened` items, with subjects `["diff", "S3"]` and `["diff", "S5"]`

### Requirement: Item IDs are rule plus subject digest
An item's `id` SHALL be `<rule>:<digest>`, where `<digest>` is the lowercase hex SHA-256 of the canonical JSON of the item's subject. A split `question` item's subject is `[<question id>]` and a split `open_item`'s is `[<index>, <risk>]`, with `<index>` its zero-based position in `left_open` as a decimal string; other items use their reason's subject. The same rule and subject MUST give the same `id` at every head. An `id` identifies an item only together with the head it was read at.

#### Scenario: Stable ID across reads
- **WHEN** a client reads the packet twice at the same head
- **THEN** every item has the same `id` in both reads

#### Scenario: Same subject at a new head
- **WHEN** a `path_match` reason with the same glob and matched paths fires at head `a1b2c3d…` and at a later head `d4e5f6a…`
- **THEN** both packets have an item with the same `id`, and an answer given at `a1b2c3d…` does not appear on the item at `d4e5f6a…`

### Requirement: Item data per kind
Each item's `data` SHALL carry what a reviewer needs for its kind, from stored inputs at the head. Hunks MUST come only from the claims document's `decisions`; the server MUST NOT serve any other diff content. The kinds are listed in this requirement's scenarios; an item of any other kind MUST NOT be served.

#### Scenario: Scenario set approval item
- **WHEN** the item kind is `scenario_set_approval`
- **THEN** `data` has the set `digest`, `version`, the last approved `digest` or null, and the version comparison by scenario ID with weakening changes (Must removed, Must demoted) listed first

#### Scenario: Diff-only set item
- **WHEN** the item kind is `diff_only_set`
- **THEN** `data` has the diff set `digest`, `revision`, and its scenario IDs with priorities and results from counted runs

#### Scenario: Weakened diff set item
- **WHEN** the item kind is `diff_set_weakened`
- **THEN** `data` has the scenario `id`, the `change` (`removed` or `demoted`), `from_priority` and `to_priority`, the current diff `version` and `digest`, the baseline `version` and `digest`, and `edited_musts`: the IDs of scenarios that are `must` in both the baseline and the current version and whose section digest differs, or `[]`

#### Scenario: Failed scenario item
- **WHEN** the item kind is `failed_scenario` (from a `should_failed` reason)
- **THEN** `data` has the scenario `id` and `priority` `should`, the set `digest`, the counted run's `run_id`, `commit`, `failed_step` and `reason`, and its artifacts

#### Scenario: Not run item
- **WHEN** the item kind is `not_run` (from a `should_not_run` reason)
- **THEN** `data` has the scenario `id`, `priority` `should`, the set `digest`, and the newest counted run's `run_id` and `reason`

#### Scenario: Spec gap item data
- **WHEN** the item kind is `spec_gap` (from a `spec_gap` reason)
- **THEN** `data` has the coverage row's `capability`, `requirement` and `scenario`, the intent set `digest` and `version`, and `covering_claims`: each `safe_because` entry at the head whose `covers` names that row (all below `claims.min_proof_level`, or the gap would be closed) with `fact`, `proof` and `evidence`, or `[]`

#### Scenario: One-way door item
- **WHEN** the item kind is `one_way_door`
- **THEN** `data` has `door_reason`, `reach`, and every claims `decisions` entry with `id`, `path`, `hunk` and `note`

#### Scenario: Unproven claim item
- **WHEN** the item kind is `unproven_claim` (from a `proof_below_minimum` reason)
- **THEN** `data` has `min_proof_level` and every `safe_because` entry below it with `fact`, `location`, `proof`, `evidence` and `covers` (absent ones as null)

#### Scenario: Open item
- **WHEN** the item kind is `open_item`
- **THEN** `data` has the `left_open` entry's `risk`, `location` and `affected`

#### Scenario: Question item
- **WHEN** the item kind is `question`
- **THEN** `data` has the question's `id`, `text`, `options` and `recommendation`

#### Scenario: Sensitive path item
- **WHEN** the item kind is `sensitive_path` (from a `path_match` reason, one item per policy entry)
- **THEN** `data` has the policy `glob`, the matched files with `path`, `old_path`, `additions` and `deletions`, and the claims `decisions` whose `path` is among them

#### Scenario: Size item
- **WHEN** the item kind is `size` (one item per `max_changed_files` or `max_changed_lines` reason)
- **THEN** `data` has `limit` (`max_changed_files` or `max_changed_lines`, the item's rule), `changed_files`, `changed_lines`, `max_changed_files` and `max_changed_lines`

#### Scenario: Unmapped area item
- **WHEN** the item kind is `unmapped_area`
- **THEN** `data` has the changed paths that match no feature's globs and the feature index version

#### Scenario: Undriven feature item
- **WHEN** the item kind is `undriven_feature`
- **THEN** `data` has the feature `id`, `title`, and the changed paths that map to it

### Requirement: Artifact URLs are presigned per read
Each artifact in an item's `data` SHALL have `id`, `content_type`, `size`, `url` and `expires_at`. `url` MUST be a presigned GET URL created on that packet read and valid for 15 minutes. An artifact whose object was deleted by retention MUST have `url` and `expires_at` null and `expired` `true`. A project without object storage MUST return `url` null.

#### Scenario: URL expiry
- **WHEN** a client reads the packet at `2026-11-21T10:00:00Z` and the failed scenario has a screenshot artifact
- **THEN** the artifact's `expires_at` is `2026-11-21T10:15:00Z` and a GET of `url` after that time is refused by object storage

#### Scenario: Fresh URLs on each read
- **WHEN** a client reads the same packet twice, 20 minutes apart
- **THEN** the second read returns artifact URLs that are valid for 15 minutes from the second read

#### Scenario: Expired artifact
- **WHEN** a counted run's artifacts were deleted by retention
- **THEN** each artifact in the packet has `expired` `true`, `url` null and `expires_at` null

### Requirement: Each kind allows fixed answers
An item's `answers` SHALL be `["approve", "reject"]` for `scenario_set_approval` and `diff_set_weakened`, `["choose", "request_change"]` for `question`, and `["approve", "request_change"]` for every other kind. `accept_as_known` MUST NOT exist.

#### Scenario: Allowed answers in the packet
- **WHEN** a packet has a `question`, a `one_way_door` and a `scenario_set_approval` item
- **THEN** their `answers` are `["choose", "request_change"]`, `["approve", "request_change"]` and `["approve", "reject"]`

#### Scenario: Weakened diff set answers
- **WHEN** a packet has a `diff_set_weakened` item
- **THEN** its `answers` are `["approve", "reject"]`

### Requirement: Answer an item
`POST /api/v1/projects/:project/change-requests/:number/review/items/:item_id/answers` SHALL accept a JSON body with `head` (required; null exactly when no `git-facts` report exists), `answer` (`approve`, `reject`, `request_change` or `choose`), `option` (required for `choose`, forbidden otherwise) and `note` (1 to 10,000 UTF-8 bytes; required for `reject` and `request_change`, optional otherwise). Any other key MUST return `422`. A stored answer SHALL return `201` with the answer.

#### Scenario: Approve an item
- **WHEN** an `sk_` client posts `{"head": "<current head>", "answer": "approve"}` to a `one_way_door` item
- **THEN** the API responds `201` and the packet shows that answer on the item

#### Scenario: Request change without a note
- **WHEN** a client posts `{"head": "<current head>", "answer": "request_change"}`
- **THEN** the API responds `422` with an error on `note` and stores nothing

#### Scenario: Option on approve
- **WHEN** a client posts `{"head": "<current head>", "answer": "approve", "option": "a"}`
- **THEN** the API responds `422` with an error on `option`

#### Scenario: Unknown key
- **WHEN** a client posts a body containing `channel`
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

### Requirement: Answers are validated against the item
The answer MUST be one of the item's `answers`, or the API returns `422` on `answer`. For `choose`, `option` MUST equal one of the question's `options`, or the API returns `422` on `option`. An `item_id` that is not an item of the packet at the current head MUST return `404`.

#### Scenario: Choose a listed option
- **WHEN** a question item has `options` `["keep", "drop"]` and a client answers `{"answer": "choose", "option": "drop"}` at the current head
- **THEN** the API responds `201` and stores option `drop`

#### Scenario: Choose an option not listed
- **WHEN** a client answers that question with `{"answer": "choose", "option": "maybe"}`
- **THEN** the API responds `422` with an error on `option` and stores nothing

#### Scenario: Answer not allowed for the kind
- **WHEN** a client answers a `one_way_door` item with `reject`
- **THEN** the API responds `422` with an error on `answer`

#### Scenario: Pending reason is not an item
- **WHEN** a client posts an answer to `required_workflow_missing:<digest>` for a missing `ci` run
- **THEN** the API responds `404` and stores nothing

### Requirement: Answers bind to the head
Each answer SHALL store the item `id`, `kind`, `rule`, the head it was given at, `answer`, `option`, `note`, the membership, the key, the channel (`cli`) and the time. A `head` in the body that is not the change request's current head MUST return `409` with the current head and store nothing. Only answers at the current head SHALL count and appear in the packet.

#### Scenario: Stale head
- **WHEN** a client answers with `head` `a1b2c3d…` after head `d4e5f6a…` was reported
- **THEN** the API responds `409` with `head` `d4e5f6a…` and stores nothing

#### Scenario: Recorded fields
- **WHEN** a client answers `choose` with option `keep` and note `fine for v1`
- **THEN** the stored answer has the item `id`, the head, `choose`, `keep`, `fine for v1`, the key's membership and key, and channel `cli`

### Requirement: A new head starts a full review
When a `git-facts` report sets a new head, every item of the new head's packet SHALL have `answer` null. Answers at other heads MUST be kept but MUST NOT count. Answers MUST NOT carry to a new head even when an item's `id` is unchanged. When a re-report makes an earlier head current again, the answers given at that head SHALL count again.

#### Scenario: Push after approval
- **WHEN** every item of change request 42 is approved at head `a1b2c3d…` and the client reports head `d4e5f6a…` with the same reasons
- **THEN** every item of the new packet has `answer` null and the verdict is `needs_review`

#### Scenario: Earlier head reported again
- **WHEN** every item was approved at head `a1b2c3d…`, head `d4e5f6a…` was then reported, and the identical `a1b2c3d…` report is sent again
- **THEN** the packet's items show the answers given at `a1b2c3d…` and the verdict counts them

### Requirement: A later answer replaces an earlier one
A second answer to the same item at the same head SHALL replace the first: the packet and the verdict MUST use only the latest. An `open` task created by the replaced answer SHALL become `stale`.

#### Scenario: Change of mind
- **WHEN** a reviewer answers an item `request_change` and then `approve` at the same head
- **THEN** the item's `answer` is `approve`, the verdict counts the item as cleared, and the task from the first answer is `stale`

### Requirement: Who may answer
Any `sk_` key of the account SHALL answer any item except `scenario_set_approval` and `diff_set_weakened`. Answers on those two kinds MUST follow the policy's `scenarios.approver`: `any` allows any `sk_` key, `other_member` requires a membership other than the one that opened the change request, and `admin` requires an owner or admin. A refused answer MUST return `403` and store nothing. `pk_` and `ck_` keys MUST return `403`.

#### Scenario: Author approves under other_member
- **WHEN** `scenarios.approver` is `other_member` and the membership that opened the change request answers `approve` on its `scenario_set_approval` item
- **THEN** the API responds `403` and stores nothing

#### Scenario: Author accepts a weakened diff set under other_member
- **WHEN** `scenarios.approver` is `other_member` and the membership that opened the change request answers `approve` on its `diff_set_weakened` item
- **THEN** the API responds `403` and stores nothing

#### Scenario: Non-admin answers a one-way door
- **WHEN** `scenarios.approver` is `admin` and a member who is not admin answers `approve` on a `one_way_door` item
- **THEN** the API responds `201`

#### Scenario: Public key answers
- **WHEN** a client with a `pk_` key posts an answer
- **THEN** the API responds `403` and stores nothing

### Requirement: Scenario set approval answers act on the digest
An `approve` answer on a `scenario_set_approval` item SHALL record the same `approve` decision on the set digest as the scenario set approval call, bound to the digest rather than the head. A `reject` answer SHALL record the same `reject` decision, with the answer's note, as the scenario set rejection call, and also create a task. The decision, the answer, any task and their events MUST commit in one transaction.

#### Scenario: Approve through the packet
- **WHEN** an allowed member answers `approve` on the `scenario_set_approval` item for digest `5e1c…`
- **THEN** digest `5e1c…` is approved, and after a new head with the same intent set no `scenario_set_approval` item appears

#### Scenario: Approve before code
- **WHEN** change request 42 has no `git-facts` report and an allowed member posts `{"head": null, "answer": "approve"}` on its `scenario_set_approval` item for digest `5e1c…`
- **THEN** the API responds `201`, digest `5e1c…` is approved, and the stored answer has `head` null

#### Scenario: Reject a set
- **WHEN** an allowed member answers `reject` with note `S2 tests the wrong path` on digest `5e1c…`
- **THEN** a `reject` decision on `5e1c…` with that note is stored, `5e1c…` reads as `approved` false, a task with that note is created, and the item stays open

### Requirement: Repeated set decisions through answers add no decision
A scenario set decision made through an answer SHALL follow the qa-scenario-sets decision rules: one equal (`decision` and `note`) to the digest's latest decision by the same membership MUST add no decision row and no `scenario_set_approved` or `scenario_set_rejected` event. The answer SHALL still be stored and return `201`.

#### Scenario: Reject twice with the same note
- **WHEN** membership M answers `reject` with note `S2 tests the wrong path` on digest `5e1c…` twice at the same head
- **THEN** both answers respond `201`, one `reject` decision row exists, the second answer replaces the first, and the first answer's task is `stale`

### Requirement: Answers only on live change requests
Answers SHALL be accepted only while the change request is `draft` or `open`. An answer to a `merged` or `closed` change request MUST return `409` and store nothing. This check MUST come before body validation, the head check, the item lookup and the `scenarios.approver` check, so an invalid body, a stale head, an unknown item or a refused approver on a `merged` or `closed` change request still gets `409`, as for the scenario set decision routes.

#### Scenario: Answer after close
- **WHEN** a client answers an item of a `closed` change request
- **THEN** the API responds `409` and stores nothing

#### Scenario: Refused approver after close
- **WHEN** `scenarios.approver` is `other_member` and the membership that opened a `closed` change request answers `approve` on a `scenario_set_approval` item id
- **THEN** the API responds `409`, not `403`, and stores nothing

### Requirement: Request change and reject create tasks
A `request_change` or `reject` answer SHALL create a task with `id`, `number`, `item_id`, `kind`, `answer`, `note`, `head`, `state` `open`, the answering membership, and the time. Approve and choose MUST NOT create tasks.

#### Scenario: Task from request change
- **WHEN** a reviewer answers `request_change` with note `add a down migration` at head `a1b2c3d…`
- **THEN** an `open` task exists with that note, head `a1b2c3d…` and the item's `id`

### Requirement: List and complete tasks
`GET /api/v1/projects/:project/change-requests/:number/tasks` SHALL return the change request's tasks oldest first, filtered by `state` (`open`, `stale` or `done`; default `open` and `stale`). `POST .../tasks/:task_id/done` SHALL set an `open` or `stale` task to `done` with the membership and time and return `200`; a `done` task returns `200` unchanged. Both routes require an `sk_` key; `pk_` and `ck_` keys get `403`. An unknown task returns `404`.

#### Scenario: Agent lists open tasks
- **WHEN** change request 42 has 1 `open`, 1 `stale` and 1 `done` task and the agent lists without `state`
- **THEN** the API responds `200` with the `open` and `stale` tasks

#### Scenario: Mark done
- **WHEN** the agent posts done for an `open` task
- **THEN** the API responds `200` and the task's `state` is `done`

#### Scenario: Invalid state filter
- **WHEN** a client lists with `state=closed`
- **THEN** the API responds `422` with an error on `state`

### Requirement: A new head makes open tasks stale
When a new head is reported, every `open` task of the change request SHALL become `stale`. Tasks MUST NOT be closed automatically. A `stale` task MUST keep its note and original head.

#### Scenario: Push after a task
- **WHEN** change request 42 has an `open` task from head `a1b2c3d…` and the client reports head `d4e5f6a…`
- **THEN** the task's `state` is `stale` and its `head` is still `a1b2c3d…`

### Requirement: Review routes are in the OpenAPI document
The packet, answer, task list and task done routes SHALL be described in `/api/v1/openapi` with their request bodies, response schemas, the item kinds, the answer kinds, and every status code in this capability.

#### Scenario: OpenAPI lists the answer route
- **WHEN** a client reads `/api/v1/openapi`
- **THEN** it describes `POST /api/v1/projects/{project}/change-requests/{number}/review/items/{item_id}/answers` with responses `201`, `401`, `403`, `404`, `409` and `422`

### Requirement: Weakened diff set answers bind to the diff digest
A `diff_set_weakened` answer SHALL count, clear its item and appear in the packet only while the diff digest that was current when it was given is still current. Storing a new diff version MUST make every earlier `diff_set_weakened` answer stop counting, at every head, so a new diff version at the same head needs new answers.

#### Scenario: Re-upload at the same head
- **WHEN** at head H on diff digest `d2` the `diff_set_weakened` item for `S3` is answered `approve`, and diff version 3 with digest `d3`, naming H and still demoting `S3`, is uploaded
- **THEN** the item for `S3` has `answer` null and the verdict is `needs_review`

#### Scenario: Earlier answer does not complete a later version
- **WHEN** on digest `d2` `S3` was answered `approve`, then `d3` is uploaded at the same head with weakened `S3` and `S5`, and only `S5` is answered `approve`
- **THEN** no decision is recorded on `d3` and the verdict stays `needs_review`

### Requirement: Weakened diff set answers act on the digest
When an `approve` answer leaves every `diff_set_weakened` item answered `approve` on the current diff digest, the server MUST also record an `approve` decision on that digest, with the membership and key of that answer. A `reject` answer MUST record a `reject` decision with its note on that digest and create a task. These MUST commit in one transaction with the answer.

#### Scenario: Accept the only weakening
- **WHEN** the only item is `diff_set_weakened` for `S3` on diff digest `d2` and an allowed member answers `approve`
- **THEN** `d2` is accepted, version 2 becomes the baseline, and the verdict has no `diff_set_weakened` reason

#### Scenario: One of two weakenings accepted
- **WHEN** `diff_set_weakened` items exist for `S3` and `S5` on digest `d2` and only `S3` is answered `approve`
- **THEN** no decision is recorded on `d2`, the verdict stays `needs_review`, and its `review` is `{"items": 2, "cleared": 1}`

#### Scenario: Decision records the completing answer
- **WHEN** member M approves the item for `S3` and member N then approves the item for `S5` on digest `d2`
- **THEN** one `approve` decision on `d2` exists, made by N with N's key and `channel` `cli`

#### Scenario: Next push after acceptance
- **WHEN** `d2` was accepted and the agent uploads diff version 3 for a new head that keeps every scenario of version 2
- **THEN** the new head's packet has no `diff_set_weakened` item

#### Scenario: Reject a weakening
- **WHEN** an allowed member answers `reject` with note `S3 must stay a Must` on the `diff_set_weakened` item for digest `d2`
- **THEN** a `reject` decision on `d2` with that note is stored, a task with that note is created, and the item stays open

#### Scenario: Reject twice with the same note
- **WHEN** membership M answers `reject` with note `S3 must stay a Must` on the same `diff_set_weakened` item of digest `d2` twice at the same head
- **THEN** both answers respond `201` and one `reject` decision row exists on `d2`
