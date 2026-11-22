## MODIFIED Requirements

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
