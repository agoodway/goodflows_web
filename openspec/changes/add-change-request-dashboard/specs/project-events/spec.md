## MODIFIED Requirements

### Requirement: Events have a fixed shape
Each event SHALL have `id` (its cursor), `type`, `number` (the change request number, or null when the event concerns none), `data`, `actor` and `inserted_at`. `actor` SHALL be `user_id` and `key_id` for an event caused by an API key, `user_id` with `key_id` null for an event caused by a signed-in member in the dashboard, and null for server-made events. `type` MUST be one of the types listed in this requirement's scenarios.

#### Scenario: Event fields
- **WHEN** a client reads a `verdict_changed` event for change request 42
- **THEN** the event has `id`, `type` `verdict_changed`, `number` `42`, `data`, `actor` and `inserted_at`

#### Scenario: Event types
- **WHEN** a client reads the feed
- **THEN** each event's `type` is one of `cr_state_changed`, `cr_retargeted`, `cr_parent_changed`, `verdict_changed`, `scenario_set_uploaded`, `scenario_set_approved`, `scenario_set_rejected`, `answer_recorded`, `task_created`, `task_completed`, `policy_version_created`, `lease_acquired`, `lease_renewed`, `lease_expired`, `lease_released` and `defect_recorded`

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

## ADDED Requirements

### Requirement: Change request edits are recorded in the project feed
The feed SHALL record `cr_retargeted` when a retarget changes a change request's target branch, `cr_parent_changed` when setting or clearing a parent changes it, and `task_completed` when a task moves to `done`. Each is written in the transaction that makes the change, with the change request's `number`. Its `actor` is the request's key and that key's membership. A call that changes nothing, such as a retarget to the current target, a parent set to the current parent, or completing a task that is already `done`, MUST record no event. The OpenAPI document SHALL list the three types among the feed's event types, with the payload fields of each.

#### Scenario: Retarget records one event
- **WHEN** an `sk_` key retargets change request 42 from `main` to `release/2`
- **THEN** the feed gains one `cr_retargeted` event with `number` `42` and that key as `actor`

#### Scenario: Completing a done task again
- **WHEN** task `T1` is already `done` and a client completes it again
- **THEN** no `task_completed` event is recorded

#### Scenario: Rejected retarget
- **WHEN** a retarget responds with an error
- **THEN** no `cr_retargeted` event is recorded
