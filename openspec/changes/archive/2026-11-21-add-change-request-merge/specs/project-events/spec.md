# Spec Delta

## MODIFIED Requirements

### Requirement: Events have a fixed shape
Each event SHALL have `id` (its cursor), `type`, `number` (the change request number, or null when the event concerns none), `data`, `actor` (`user_id` and `key_id`, or null for server-made events) and `inserted_at`. `type` MUST be one of the types listed in this requirement's scenarios.

#### Scenario: Event fields
- **WHEN** a client reads a `verdict_changed` event for change request 42
- **THEN** the event has `id`, `type` `verdict_changed`, `number` `42`, `data`, `actor` and `inserted_at`

#### Scenario: Event types
- **WHEN** a client reads the feed
- **THEN** each event's `type` is one of `cr_state_changed`, `verdict_changed`, `scenario_set_uploaded`, `scenario_set_approved`, `scenario_set_rejected`, `answer_recorded`, `task_created`, `policy_version_created`, `lease_acquired`, `lease_renewed`, `lease_expired`, `lease_released` and `defect_recorded`

#### Scenario: Event without a change request
- **WHEN** a client reads a `policy_version_created` event or the `defect_recorded` event of an unattributed defect
- **THEN** its `number` is null

#### Scenario: Lease event fields
- **WHEN** a client reads a `lease_acquired` event for change request 42
- **THEN** the change request number is the top-level `number` `42`, the acquiring key is the top-level `actor`, and `data` holds neither

### Requirement: Each event type carries its change
The `data` of each event type SHALL hold the fields in this requirement's scenarios and no others.

#### Scenario: State change
- **WHEN** change request 42 moves from `draft` to `open`
- **THEN** a `cr_state_changed` event has `data` `{"from": "draft", "to": "open"}`

#### Scenario: Verdict change
- **WHEN** change request 42's verdict at head `a1b2c3d…` and policy version 7 changes from `needs_review` to `mergeable`
- **THEN** a `verdict_changed` event has `data` with `from` `needs_review`, `to` `mergeable`, `head` `a1b2c3d…` and `policy_version` `7`

#### Scenario: Recomputed verdict with the same state
- **WHEN** a verdict is recomputed and its state, head and policy version are unchanged
- **THEN** no `verdict_changed` event is written

#### Scenario: Scenario set uploaded
- **WHEN** a new version of change request 42's intent set is stored
- **THEN** a `scenario_set_uploaded` event has `data` with `source` `intent`, `digest` and `version`

#### Scenario: Scenario set approved
- **WHEN** digest `5e1c…` of change request 42's intent set is approved
- **THEN** a `scenario_set_approved` event has `data` with `digest` `5e1c…`

#### Scenario: Scenario set rejected
- **WHEN** digest `5e1c…` of change request 42's intent set is rejected with note `S2 tests the wrong path`, through the rejection call or a `reject` answer
- **THEN** a `scenario_set_rejected` event has `data` with `digest` `5e1c…` and `note` `S2 tests the wrong path`

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

## ADDED Requirements

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
