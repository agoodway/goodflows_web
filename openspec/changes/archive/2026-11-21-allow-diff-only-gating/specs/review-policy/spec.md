## MODIFIED Requirements

### Requirement: Each section holds fixed keys
The allowed keys SHALL be: `scenarios`: `require_approved_intent`, `should_failures`, `spec_gaps`, `approver`, `diff_only`; `evidence`: `required_workflows`, `ignore_paths`; `claims`: `one_way_door`, `min_proof_level`, `open_items`; `paths`: a list of `{glob, outcome}`; `size`: `max_changed_files`, `max_changed_lines`; `coverage`: `unmapped_areas`, `undriven_features`; `merge`: `lease_ttl`, `regrade_merge_result`. Any other key MUST return `422` on that key.

#### Scenario: Unknown key in a section
- **WHEN** an admin writes a policy with `claims.max_open_items` `3`
- **THEN** the API responds `422` with `has an unknown field` on `policy.claims` and stores nothing

#### Scenario: Unknown key in a paths entry
- **WHEN** an admin writes a `paths` entry `{"glob": "app/priv/**", "outcome": "blocked", "note": "db"}`
- **THEN** the API responds `422` on `policy.paths[<index>]` and stores nothing

#### Scenario: Diff-only key accepted
- **WHEN** an admin writes a policy with `scenarios.diff_only` `weakening`
- **THEN** the API responds `201` and the stored `policy` has `scenarios.diff_only` `weakening`

### Requirement: Outcome settings are validated
`claims.one_way_door`, `claims.open_items`, `coverage.unmapped_areas`, `coverage.undriven_features`, and each `paths[].outcome` MUST be `needs_review`, `blocked` or `ignore`. `scenarios.should_failures` and `scenarios.spec_gaps` MUST be `needs_review` or `ignore`. `scenarios.diff_only` MUST be `needs_review`, `weakening` or `ignore`. `scenarios.approver` MUST be `any`, `other_member` or `admin`. `claims.min_proof_level` MUST be `stated`, `pointed`, `walked` or `ran`. A violation MUST return `422` on that key.

#### Scenario: Pending is not a policy outcome
- **WHEN** an admin writes a policy with `claims.one_way_door` `pending`
- **THEN** the API responds `422` with an error on `policy.claims.one_way_door`

#### Scenario: Unknown proof level
- **WHEN** an admin writes a policy with `claims.min_proof_level` `tested`
- **THEN** the API responds `422` with an error on `policy.claims.min_proof_level`

#### Scenario: Diff-only cannot block
- **WHEN** an admin writes a policy with `scenarios.diff_only` `blocked`
- **THEN** the API responds `422` with an error on `policy.scenarios.diff_only` and stores nothing

## ADDED Requirements

### Requirement: Diff-only outcome defaults to needs_review
When a policy omits `scenarios.diff_only`, including policy version 0, its `effective` document SHALL have `scenarios.diff_only` `needs_review`, so a policy written before this setting existed keeps its verdicts. `active_settings` MUST contain `scenarios.diff_only`.

#### Scenario: Older policy
- **WHEN** a client reads a policy version whose `scenarios` section has only `require_approved_intent` true
- **THEN** `effective.scenarios.diff_only` is `needs_review` and `policy` has no `diff_only` key

#### Scenario: Version 0
- **WHEN** a client reads the review policy of a project that never wrote one
- **THEN** `effective.scenarios.diff_only` is `needs_review` and `active_settings` contains `scenarios.diff_only`
