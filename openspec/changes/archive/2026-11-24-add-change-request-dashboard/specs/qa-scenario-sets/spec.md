## MODIFIED Requirements

### Requirement: Decisions record who decided and how
Each decision SHALL store `decision` (`approve` or `reject`), the membership, the key, the digest, the `note` (null for approvals), the time, and the `channel`. A decision with the `decision` and `note` of the digest's latest decision, when that was made by the same membership, MUST respond `200` and add no row. Decision responses MUST include `decision`, `digest`, `note`, `decided_by` (with `user_id`), `decided_at` and `channel`.

#### Scenario: Approval record
- **WHEN** membership M approves digest `d2` with key K
- **THEN** the response has `decision` `approve`, `digest` `d2`, `decided_by.user_id` M's user id and `channel` `cli`, and the stored row names key K

#### Scenario: Repeated approval
- **WHEN** membership M approves `d2` twice
- **THEN** the first responds `201`, the second `200`, and one decision row exists

#### Scenario: Approval again after another member's rejection
- **WHEN** membership M approves `d2`, membership N rejects `d2`, and M approves `d2` again
- **THEN** the third decision responds `201`, three decision rows exist, and `d2` reads as approved

#### Scenario: Rejection with a different note
- **WHEN** membership M rejects `d2` with note `first`, again with note `first`, then with note `second`
- **THEN** the responses are `201`, `200` and `201`, and two decision rows exist

#### Scenario: Rejection record
- **WHEN** membership M rejects `d2` with note `S2 tests the wrong path`
- **THEN** the response has `decision` `reject` and that `note`, and the row names M, the key, `d2`, the time and `channel` `cli`

#### Scenario: Public key reads decisions
- **WHEN** a client with a `pk_` key reads a version with a rejection
- **THEN** that decision has `note` null and `decided_by.user_id` null

## ADDED Requirements

### Requirement: Decisions record their channel
A decision's `channel` SHALL be `cli` for every decision made through the API, and `dashboard`, with the key null, for a decision recorded by a review answer made in the dashboard.

#### Scenario: Approval from the dashboard
- **WHEN** membership M approves the `scenario_set_approval` item for digest `d2` in the dashboard
- **THEN** `d2` reads as approved, and its decision names M, has no key, and has `channel` `dashboard`
