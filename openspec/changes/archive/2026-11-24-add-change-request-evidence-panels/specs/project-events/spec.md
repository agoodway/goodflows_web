# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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
