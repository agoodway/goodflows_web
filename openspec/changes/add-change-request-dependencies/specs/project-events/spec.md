# Spec Delta

## MODIFIED Requirements

### Requirement: Events have a fixed shape
Each event SHALL have `id` (its cursor), `type`, `number` (the change request number, or null when the event concerns none), `data`, `actor` and `inserted_at`. `actor` SHALL be `user_id` and `key_id` for an event caused by an API key, `user_id` with `key_id` null for an event caused by a signed-in member in the dashboard, and null for server-made events. `type` MUST be one of the types listed in this requirement's scenarios.

#### Scenario: Event fields
- **WHEN** a client reads a `verdict_changed` event for change request 42
- **THEN** the event has `id`, `type` `verdict_changed`, `number` `42`, `data`, `actor` and `inserted_at`

#### Scenario: Event types
- **WHEN** a client reads the feed
- **THEN** each event's `type` is one of `cr_state_changed`, `cr_retargeted`, `cr_parent_changed`, `cr_dependencies_changed`, `verdict_changed`, `scenario_set_uploaded`, `scenario_set_approved`, `scenario_set_rejected`, `answer_recorded`, `task_created`, `task_completed`, `policy_version_created`, `lease_acquired`, `lease_renewed`, `lease_expired`, `lease_released`, `defect_recorded`, `workflow_run_stored` and `verify_run_stored`

#### Scenario: Event without a change request
- **WHEN** a client reads a `policy_version_created` event or the `defect_recorded` event of an unattributed defect
- **THEN** its `number` is null

#### Scenario: Lease event fields
- **WHEN** a client reads a `lease_acquired` event for change request 42
- **THEN** the change request number is the top-level `number` `42`, the acquiring key is the top-level `actor`, and `data` holds neither

#### Scenario: Dashboard answer event
- **WHEN** member M answers an item of change request 42 in the dashboard and an `sk_` client then reads the feed
- **THEN** the `answer_recorded` event has `number` `42` and `actor` with M's `user_id` and `key_id` null

## ADDED Requirements

### Requirement: Dependency changes are recorded in the project feed
The feed SHALL record `cr_dependencies_changed` when a dependencies update changes a change request's stored list, with `data` `{"from": [...], "to": [...]}` (the old and new lists, `[]` for none), in the transaction that makes the change, with the change request's `number`. Its `actor` is the request's key and that key's membership. An update that sends the stored list again, or a rejected update, MUST record no event.

#### Scenario: Dependencies set, then cleared
- **WHEN** change request 42's dependencies change from none to `["add-login"]`, then to none
- **THEN** two `cr_dependencies_changed` events have `data` `{"from": [], "to": ["add-login"]}` and `{"from": ["add-login"], "to": []}`

#### Scenario: Same list again
- **WHEN** change request 42's dependencies are `["add-login"]` and a client puts `{"change_ids": ["add-login"]}`
- **THEN** no `cr_dependencies_changed` event is recorded

#### Scenario: OpenAPI lists the dependencies event
- **WHEN** a client reads the OpenAPI document
- **THEN** the project event types include `cr_dependencies_changed`, with its payload fields
