# project-events Specification

## Purpose

Gives clients and agents an append-only, per-project feed of change request activity with a keyset cursor and an optional long-poll, so they learn about state, verdict, scenario set, answer, task and policy changes without tight polling.

## Requirements

### Requirement: Read a project's event feed
`GET /api/v1/projects/:project/events` SHALL accept any valid `sk_` or `pk_` key of the project's account and return `data` (events, oldest first) and `next_cursor`. Missing, expired or revoked keys MUST return `401`; `ck_` keys MUST return `403`. An invalid project slug returns `422` on `project`; an unknown project, including another account's, returns `404`. A request whose `Accept` does not allow `application/json` MUST return `406`.

#### Scenario: Private key reads events
- **WHEN** a client with an `sk_` key reads the events of a project with 3 events
- **THEN** the API responds `200` with the 3 events oldest first

#### Scenario: Cache key
- **WHEN** a client with a `ck_` key reads events
- **THEN** the API responds `403`

#### Scenario: Another account's project
- **WHEN** a client reads events of a slug that exists only on another account
- **THEN** the API responds `404`

### Requirement: Events have a fixed shape
Each event SHALL have `id` (its cursor), `type`, `number` (the change request number, or null when the event concerns none), `data`, `actor` and `inserted_at`. `actor` SHALL be `user_id` and `key_id` for an event caused by an API key, `user_id` with `key_id` null for an event caused by a signed-in member in the dashboard, and null for server-made events. `type` MUST be one of the types listed in this requirement's scenarios.

#### Scenario: Event fields
- **WHEN** a client reads a `verdict_changed` event for change request 42
- **THEN** the event has `id`, `type` `verdict_changed`, `number` `42`, `data`, `actor` and `inserted_at`

#### Scenario: Event types
- **WHEN** a client reads the feed
- **THEN** each event's `type` is one of `cr_state_changed`, `cr_retargeted`, `cr_parent_changed`, `verdict_changed`, `scenario_set_uploaded`, `scenario_set_approved`, `scenario_set_rejected`, `answer_recorded`, `task_created`, `task_completed`, `policy_version_created`, `lease_acquired`, `lease_renewed`, `lease_expired`, `lease_released`, `defect_recorded`, `workflow_run_stored` and `verify_run_stored`

#### Scenario: Event without a change request
- **WHEN** a client reads a `policy_version_created` event or the `defect_recorded` event of an unattributed defect
- **THEN** its `number` is null

#### Scenario: Lease event fields
- **WHEN** a client reads a `lease_acquired` event for change request 42
- **THEN** the change request number is the top-level `number` `42`, the acquiring key is the top-level `actor`, and `data` holds neither

#### Scenario: Dashboard answer event
- **WHEN** member M answers an item of change request 42 in the dashboard and an `sk_` client then reads the feed
- **THEN** the `answer_recorded` event has `number` `42` and `actor` with M's `user_id` and `key_id` null

### Requirement: Each event type carries its change
The `data` of each event type SHALL hold the fields in this requirement's scenarios and no others. A `verdict_changed` event SHALL be written whenever a recompute changes anything the stored verdict shows: its state, head, policy version, reasons, scenarios, coverage, counted runs or review counts. A recompute that changes none of these MUST write no `verdict_changed` event.

#### Scenario: State change
- **WHEN** change request 42 moves from `draft` to `open`
- **THEN** a `cr_state_changed` event has `data` `{"from": "draft", "to": "open"}`

#### Scenario: Verdict change
- **WHEN** change request 42's verdict at head `a1b2c3d…` and policy version 7 changes from `needs_review` to `mergeable`
- **THEN** a `verdict_changed` event has `data` with `from` `needs_review`, `to` `mergeable`, `head` `a1b2c3d…` and `policy_version` `7`

#### Scenario: Recomputed verdict with the same state
- **WHEN** a verify run on change request 42's head clears its `should_not_run` reason, and the verdict stays `needs_review` because of a `one_way_door` reason
- **THEN** a `verdict_changed` event has `data` with `from` `needs_review` and `to` `needs_review`

#### Scenario: Recomputed verdict with nothing changed
- **WHEN** a verdict is recomputed and its state, head, policy version, reasons, scenarios, coverage, counted runs and review counts are unchanged
- **THEN** no `verdict_changed` event is written

#### Scenario: Retarget
- **WHEN** change request 42's target branch changes from `main` to `release/2`
- **THEN** a `cr_retargeted` event has `data` `{"from": "main", "to": "release/2"}`

#### Scenario: Parent set, changed or cleared
- **WHEN** change request 42's parent changes from none to 41, then from 41 to 40, then to none
- **THEN** three `cr_parent_changed` events have `data` `{"from": null, "to": 41}`, `{"from": 41, "to": 40}` and `{"from": 40, "to": null}`

#### Scenario: Task completed
- **WHEN** task `T1`, created for item `one_way_door:<digest>` of change request 42, is completed
- **THEN** a `task_completed` event has `data` `{"task_id": "T1", "item_id": "one_way_door:<digest>"}`

#### Scenario: Scenario set uploaded
- **WHEN** a new version of change request 42's intent set is stored
- **THEN** a `scenario_set_uploaded` event has `data` with `source` `intent`, `digest` and `version`

#### Scenario: Scenario set approved
- **WHEN** digest `5e1c…` of change request 42's intent set is approved
- **THEN** a `scenario_set_approved` event has `data` with `source` `intent` and `digest` `5e1c…`

#### Scenario: Scenario set rejected
- **WHEN** digest `5e1c…` of change request 42's intent set is rejected with note `S2 tests the wrong path`, through the rejection call or a `reject` answer
- **THEN** a `scenario_set_rejected` event has `data` with `source` `intent`, `digest` `5e1c…` and `note` `S2 tests the wrong path`

#### Scenario: Diff set accepted
- **WHEN** digest `d2` of change request 43's diff set is accepted through `diff_set_weakened` answers
- **THEN** a `scenario_set_approved` event has `data` with `source` `diff` and digest `d2`

#### Scenario: Diff set weakening rejected
- **WHEN** a `reject` answer with note `S3 must stay a Must` is given on a `diff_set_weakened` item of digest `d2`
- **THEN** a `scenario_set_rejected` event has `data` with `source` `diff`, `digest` `d2` and that `note`

#### Scenario: Merge report
- **WHEN** change request 42 is reported merged from `open`
- **THEN** a `cr_state_changed` event has `data` `{"from": "open", "to": "merged"}`

#### Scenario: Answer recorded
- **WHEN** an answer is stored on an item of change request 42
- **THEN** an `answer_recorded` event has `data` with `item_id`, `kind`, `head`, `answer`, `option` and `note`

#### Scenario: Task created
- **WHEN** a `request_change` answer creates a task
- **THEN** a `task_created` event has `data` with `task_id`, `item_id`, `head` and `note`

#### Scenario: Policy version created
- **WHEN** an admin writes policy version 8 with note `tighten migrations`
- **THEN** a `policy_version_created` event has `number` null and `data` `{"version": 8, "note": "tighten migrations"}`

#### Scenario: Lease acquired, renewed or expired
- **WHEN** lease `L1` of change request 42 on `main` is acquired, renewed or expired
- **THEN** the `lease_acquired`, `lease_renewed` or `lease_expired` event has `data` `{"lease_id": "L1", "target_branch": "main", "expires_at": <the lease's expires_at after the change>}`

#### Scenario: Lease released
- **WHEN** lease `L1` of change request 42 on `main` is released by the release route, a merge report or a close
- **THEN** a `lease_released` event has `data` with `lease_id`, `target_branch`, `expires_at` and `release_reason` `released`, `merged` or `closed`

#### Scenario: Defect recorded
- **WHEN** a defect is stored
- **THEN** a `defect_recorded` event has `data` with `defect_id`, `commit` (or null), `attribution`, `severity` (or null) and `ticket` (or null)

### Requirement: Events commit with the change they describe
An event SHALL be inserted in the same transaction as the change it describes. A change that rolls back MUST leave no event, and a committed change MUST have its event. Notifying waiting readers MUST happen only after commit.

#### Scenario: Rolled-back answer
- **WHEN** storing an answer fails after the answer row was written and the transaction rolls back
- **THEN** no `answer_recorded` event is visible

### Requirement: The cursor never skips an event
Event `id`s SHALL increase within a project in commit order: once a reader has received an event, every later-committed event of that project MUST have a higher `id`. `after` takes an event `id`; the feed SHALL return events with a greater `id`, up to `limit` (1 to 200, default 100). `next_cursor` MUST be the `id` of the last returned event, or the given `after` when none is returned. An invalid `after` or `limit` MUST return `422` on that parameter.

#### Scenario: Paging
- **WHEN** a project has 5 events and a client reads with `limit=3`, then with `after` set to the returned `next_cursor`
- **THEN** the first page has 3 events and the second has 2

#### Scenario: Nothing new
- **WHEN** a client reads with `after` equal to the newest event's `id` and `wait=0`
- **THEN** the API responds `200` with empty `data` and `next_cursor` equal to `after`

#### Scenario: Concurrent writers
- **WHEN** two transactions write events for the same project at the same time and a reader polls between their commits
- **THEN** the reader's next page with its `next_cursor` includes the event committed second

#### Scenario: Malformed cursor
- **WHEN** a client reads with `after=abc`
- **THEN** the API responds `422` with an error on `after`

### Requirement: Long-poll waits up to 30 seconds
`wait` SHALL be an integer from 0 to 30 seconds, default 0. When events exist after `after`, the feed MUST return them at once. Otherwise it SHALL wait until an event for the project commits or `wait` seconds pass, then read again and return. A waiting request MUST NOT hold a database connection. A `wait` outside 0 to 30 MUST return `422` on `wait`.

#### Scenario: Event arrives during wait
- **WHEN** a client reads with `wait=30` and no new events, and 4 seconds later a verdict changes
- **THEN** the API responds about 4 seconds after the request with the `verdict_changed` event

#### Scenario: Wait times out
- **WHEN** a client reads with `wait=5` and no event commits for 5 seconds
- **THEN** the API responds `200` after about 5 seconds with empty `data`

#### Scenario: Wait too long
- **WHEN** a client reads with `wait=31`
- **THEN** the API responds `422` with an error on `wait`

### Requirement: Waiting requests are limited per account
Each node SHALL limit concurrent waiting feed requests per account to a configured number, default 20. A request over the limit MUST be answered at once as if `wait` were 0, with status `200`.

#### Scenario: Over the limit
- **WHEN** 20 requests of one account are waiting on a node and a 21st arrives on that node with `wait=30` and no new events
- **THEN** the 21st responds `200` immediately with empty `data`

### Requirement: Events are kept 90 days
Events older than 90 days SHALL be deleted. A read whose `after` precedes events that were deleted MUST return `410` with `latest_cursor`, the `id` of the project's newest event or null, so the client resyncs from current state and continues from there. A read without `after` SHALL start at the oldest kept event.

#### Scenario: Expired cursor
- **WHEN** a client reads with an `after` whose following events were deleted by retention
- **THEN** the API responds `410` with `latest_cursor`

#### Scenario: Resume after resync
- **WHEN** the client then reads with `after` set to `latest_cursor`
- **THEN** the API responds `200` with events newer than `latest_cursor`

### Requirement: Public keys see restricted events
A `pk_` key SHALL receive every event type, with `note` in `scenario_set_rejected`, `answer_recorded`, `task_created` and `policy_version_created` set to null, `ticket` in `defect_recorded` set to null, and `actor` set to null. A field absent from an event MUST NOT be added. `sk_` keys MUST see events as stored. The stored rows MUST NOT change.

#### Scenario: Public key reads an answer event
- **WHEN** a client with a `pk_` key reads an `answer_recorded` event with note `fine for v1`
- **THEN** the event has `note` null, `actor` null, and `answer`, `item_id` and `head` as stored

#### Scenario: Public key reads a defect event
- **WHEN** a defect with `ticket: "GOO-512"` was recorded and a client with a `pk_` key reads the feed
- **THEN** the `defect_recorded` event has `actor` null, `ticket: null`, and its `number` and `severity` as recorded

#### Scenario: Private key reads a defect event
- **WHEN** the same feed is read with an `sk_` key
- **THEN** the `defect_recorded` event has `ticket: "GOO-512"`

#### Scenario: Public key reads a lease event
- **WHEN** a client with a `pk_` key reads a `lease_acquired` event
- **THEN** the event has `actor` null and its `number` and `data` as stored

### Requirement: Deleting a project deletes its events
Deleting a project SHALL delete its events. Events MUST NOT block project deletion.

#### Scenario: Project with events deleted
- **WHEN** a project with no change requests and 2 `policy_version_created` events is deleted
- **THEN** the deletion succeeds and the 2 events are gone

### Requirement: The event feed is in the OpenAPI document
`GET /api/v1/projects/{project}/events` SHALL be described in `/api/v1/openapi` with `after`, `limit` and `wait`, every event type and its `data`, and responses `200`, `401`, `403`, `404`, `406`, `410` and `422`.

#### Scenario: OpenAPI lists the feed
- **WHEN** a client reads `/api/v1/openapi`
- **THEN** it describes the events route with the `410` response and its `latest_cursor`

### Requirement: Merge lease events are recorded in the project feed
The feed SHALL record `lease_acquired` when a lease is created, `lease_renewed` on each successful heartbeat, `lease_expired` when a lease is marked expired, and `lease_released` when a lease is released, each in the transaction that makes the change. Each event's top-level `number` is the lease's change request and its `actor` the request that caused it (null for expiry); its `data` holds the fields the event type's scenario lists.

#### Scenario: Acquire
- **WHEN** CR 42 acquires lease `L1` on `main` with Ada's key
- **THEN** the feed gains one `lease_acquired` event with `number` `42`, `actor` naming Ada's `user_id` and the key, and `data` with `lease_id: "L1"`, `target_branch: "main"` and `expires_at`

#### Scenario: Heartbeat
- **WHEN** lease `L1` receives a heartbeat that moves `expires_at` to `12:18:00Z`
- **THEN** the feed gains one `lease_renewed` event with `expires_at: "…T12:18:00Z"`

#### Scenario: Retried acquire
- **WHEN** the key holding lease `L1` acquires again for the same change request and gets `200` with `L1`
- **THEN** no event is recorded

#### Scenario: Rejected heartbeat
- **WHEN** a heartbeat for an expired lease responds `409`
- **THEN** no `lease_renewed` event is recorded

#### Scenario: Expiry
- **WHEN** the expiry job marks lease `L1` expired
- **THEN** the feed gains exactly one `lease_expired` event for `L1`, with `actor` null

#### Scenario: Release by merge report
- **WHEN** CR 42 is reported merged with `lease_id` `L1`
- **THEN** the feed gains one `cr_state_changed` event and, after it in the same transaction, a `lease_released` event with `release_reason: "merged"`

#### Scenario: Release by close
- **WHEN** CR 42 is closed while holding lease `L1`
- **THEN** the feed gains a `lease_released` event with `release_reason: "closed"`

### Requirement: Defect events are recorded in the project feed
The feed SHALL record `defect_recorded` in the transaction that stores a defect. Its top-level `number` is the attributed change request (null when unattributed) and its `actor` the recording request.

#### Scenario: Attributed defect
- **WHEN** a defect naming commit `c3d4e5f` is attributed to CR 41 with `severity: "high"`
- **THEN** the feed gains one `defect_recorded` event with `number` `41` and `data` with `attribution: "commit"` and `severity: "high"`

#### Scenario: Unattributed defect
- **WHEN** a defect naming a commit no merged change request contains is recorded
- **THEN** the `defect_recorded` event has `number` null and `attribution: "unattributed"`

#### Scenario: Rejected defect
- **WHEN** a defect post responds `422`
- **THEN** no `defect_recorded` event is recorded

### Requirement: Lease and defect events are in the OpenAPI document
The OpenAPI document SHALL list `lease_acquired`, `lease_renewed`, `lease_expired`, `lease_released` and `defect_recorded` among the feed's event types, with the payload fields of each.

#### Scenario: OpenAPI lists lease events
- **WHEN** a client fetches the OpenAPI document
- **THEN** the event type enum includes `lease_expired` and `defect_recorded`

### Requirement: Change request edits are recorded in the project feed
The feed SHALL record `cr_retargeted` when a retarget changes a change request's target branch, `cr_parent_changed` when setting or clearing a parent changes it, and `task_completed` when a task moves to `done`. Each is written in the transaction that makes the change, with the change request's `number`. Its `actor` is the request's key and that key's membership.

#### Scenario: Retarget records one event
- **WHEN** an `sk_` key retargets change request 42 from `main` to `release/2`
- **THEN** the feed gains one `cr_retargeted` event with `number` `42` and that key as `actor`

#### Scenario: Rejected retarget
- **WHEN** a retarget responds with an error
- **THEN** no `cr_retargeted` event is recorded

### Requirement: Edits that change nothing record no event
A call that changes nothing, such as a retarget to the current target, a parent set to the current parent, or completing a task that is already `done`, MUST record no event.

#### Scenario: Completing a done task again
- **WHEN** task `T1` is already `done` and a client completes it again
- **THEN** no `task_completed` event is recorded

### Requirement: The OpenAPI document lists the edit events
The OpenAPI document SHALL list the three types among the feed's event types, with the payload fields of each.

#### Scenario: Edit event types in the OpenAPI document
- **WHEN** a client reads the OpenAPI document
- **THEN** the project event types include `cr_retargeted`, `cr_parent_changed` and `task_completed`, with the payload fields of each

### Requirement: Stored runs are recorded in the project feed
The feed SHALL record `workflow_run_stored` once for each `draft` or `open` change request whose head is a newly stored workflow run's commit, and `verify_run_stored` once for each `draft` or `open` change request with a scenario set version on a verify run's digest when the run becomes `final`. Each is written in the transaction that stores or finalizes the run, with the change request's `number`, and its `actor` is the uploading key and its membership.

#### Scenario: Workflow run on a head
- **WHEN** a workflow run `ci` with outcome `passed` is stored on the head of `open` change request 42
- **THEN** the feed gains one `workflow_run_stored` event with `number` `42` and `data` with `run_id`, `workflow` `ci`, `outcome` `passed` and `commit`

#### Scenario: Verify run finalized
- **WHEN** a verify run on change request 42's current diff digest becomes `final`
- **THEN** the feed gains one `verify_run_stored` event with `number` `42` and `data` with `run_id`, `commit`, `source` `diff` and `digest`

#### Scenario: Run no active change request concerns
- **WHEN** a workflow run is stored on a commit that is no active change request's head
- **THEN** no `workflow_run_stored` event is recorded

#### Scenario: Retried upload
- **WHEN** a client uploads the identical workflow run document again and gets the stored run back
- **THEN** no event is recorded

#### Scenario: Verify run still uploading
- **WHEN** a verify run with undelivered artifacts is created with status `uploading`
- **THEN** no `verify_run_stored` event is recorded until it becomes `final`

### Requirement: Run events are in the OpenAPI document
The OpenAPI document SHALL list `workflow_run_stored` and `verify_run_stored` among the feed's event types, with the payload fields of each.

#### Scenario: OpenAPI lists run events
- **WHEN** a client reads the OpenAPI document
- **THEN** the project event types include `workflow_run_stored` and `verify_run_stored`, with the payload fields of each
